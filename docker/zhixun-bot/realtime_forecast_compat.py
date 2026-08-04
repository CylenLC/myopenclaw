"""Compatibility helpers for realtime forecast plot URLs.

zhixun-core stores plots under its static ``/plots`` mount and may return a
relative URL.  The Feishu agent needs an absolute URL that it can render.
"""

from __future__ import annotations

from functools import wraps
import inspect
import os
import re
from typing import Any

import httpx
from mcp.server.fastmcp.utilities.types import Image
from mcp.types import TextContent

def _absolute_url(value: Any, base_url: str) -> Any:
    if isinstance(value, str) and value.startswith("/"):
        return f"{base_url.rstrip('/')}{value}"
    if isinstance(value, list):
        return [_absolute_url(item, base_url) for item in value]
    if isinstance(value, dict):
        return {
            key: (
                _absolute_url(item, base_url)
                if key in {"url", "plot_url", "image_url"}
                else _absolute_url(item, base_url) if isinstance(item, (dict, list)) else item
            )
            for key, item in value.items()
        }
    return value


def _plot_entries(value: Any) -> list[tuple[str, str]]:
    if isinstance(value, dict):
        plot = value.get("plot")
        if isinstance(plot, dict) and isinstance(plot.get("url"), str):
            url = plot["url"]
            if url.startswith(("http://", "https://")) and url.lower().split("?", 1)[0].endswith(
                (".png", ".jpg", ".jpeg", ".webp", ".gif")
            ):
                model = str(value.get("model_name") or value.get("model") or "预报模型")
                return [(model, url)]
        entries = []
        for key, item in value.items():
            if key != "plot":
                entries.extend(_plot_entries(item))
        return entries
    if isinstance(value, list):
        return [entry for item in value for entry in _plot_entries(item)]
    return []


def _hide_plot_urls(value: Any, attached_urls: set[str]) -> Any:
    if isinstance(value, list):
        return [_hide_plot_urls(item, attached_urls) for item in value]
    if isinstance(value, dict):
        result = {}
        for key, item in value.items():
            if key == "plot" and isinstance(item, dict) and isinstance(item.get("url"), str):
                result[key] = {
                    child_key: child_value
                    for child_key, child_value in item.items()
                    if child_key not in {"url", "file_path"}
                }
                result[key]["native_image"] = (
                    "attached" if item["url"] in attached_urls else "unavailable"
                )
            else:
                result[key] = _hide_plot_urls(item, attached_urls)
        return result
    return value


def _merge_model_runs(results: list[Any], errors: list[dict[str, str]]) -> Any:
    first = results[0]
    hal = isinstance(first, dict) and isinstance(first.get("data"), dict)
    payloads = [item["data"] if hal else item for item in results]
    merged_payload = dict(payloads[0])
    merged_payload["results"] = [
        row for payload in payloads for row in payload.get("results", [])
    ]
    merged_payload["errors"] = [
        row for payload in payloads for row in payload.get("errors", [])
    ] + errors
    if hal:
        merged = dict(first)
        merged["data"] = merged_payload
        return merged
    return merged_payload


def install(module: Any, base_url: str) -> None:
    """Wrap forecast tools so returned ``plot.url`` values are absolute."""

    def validate_model_name(value: str | None) -> str | None:
        if value is None or not value.strip():
            return None
        normalized = value.strip().lower()
        if normalized in {"simplelstm", "dhf"} or re.fullmatch(
            r"sms3-[a-z0-9-]+", normalized
        ):
            return normalized
        raise ValueError(
            "model_name 仅支持 simplelstm、dhf 或 zhixun-core 已注册的 sms3-* 模型"
        )

    if hasattr(module, "_validate_model_name"):
        module._validate_model_name = validate_model_name

    configured_models = tuple(
        dict.fromkeys(
            model.strip().lower()
            for model in os.environ.get(
                "ZHIXUN_REALTIME_FORECAST_MODELS",
                "simplelstm,dhf,sms3-lag3,sms3-uhb",
            ).split(",")
            if model.strip()
        )
    )

    names = (
        "run_realtime_forecast",
        "get_latest_realtime_forecast",
        "run_realtime_forecast_compat",
        "get_latest_realtime_forecast_compat",
    )
    for name in names:
        function = getattr(module, name, None)
        if function is None or getattr(function, "_plot_url_compat", False):
            continue

        @wraps(function)
        async def wrapped(
            *args: Any,
            __function=function,
            __name=name,
            **kwargs: Any,
        ) -> Any:
            bound = inspect.signature(__function).bind_partial(*args, **kwargs)
            requested_model = bound.arguments.get("model_name")
            if __name in {"run_realtime_forecast", "run_realtime_forecast_compat"} and not requested_model:
                model_results = []
                model_errors = []
                for model in configured_models:
                    call_kwargs = dict(bound.arguments)
                    call_kwargs["model_name"] = model
                    try:
                        model_results.append(await __function(**call_kwargs))
                    except Exception as exc:
                        model_errors.append({"model": model, "error": str(exc)})
                if not model_results:
                    raise RuntimeError(f"全部配置模型均执行失败: {model_errors}")
                result = _merge_model_runs(model_results, model_errors)
            else:
                result = await __function(*args, **kwargs)
            normalized = _absolute_url(result, base_url)
            images = []
            attached_urls = set()
            async with httpx.AsyncClient(timeout=30) as client:
                for model, url in dict.fromkeys(_plot_entries(normalized)):
                    try:
                        response = await client.get(url)
                        response.raise_for_status()
                        attached_urls.add(url)
                        images.append(
                            (
                                TextContent(
                                    type="text",
                                    text=f"{model} 降雨径流过程图",
                                ),
                                Image(data=response.content, format="png"),
                            )
                        )
                    except httpx.HTTPError:
                        # Keep the URL in the JSON result if image retrieval fails.
                        continue
            text_result = _hide_plot_urls(normalized, attached_urls)
            return (
                [text_result, *(block for pair in images for block in pair)]
                if images
                else text_result
            )

        wrapped._plot_url_compat = True
        setattr(module, name, wrapped)


def install_unified_wrapper_compat(shared: Any) -> None:
    """Preserve native image blocks through the unified JSON wrapper.

    The upstream unified wrapper JSON-serializes every tool result. Forecast
    tools are the exception because they return MCP ImageContent blocks.
    """

    original = shared.build_tool_wrapper
    image_tools = {
        "run_realtime_forecast",
        "get_latest_realtime_forecast",
        "run_realtime_forecast_compat",
        "get_latest_realtime_forecast_compat",
    }

    def build_tool_wrapper(func: Any, tool_name: str) -> Any:
        if tool_name not in image_tools:
            return original(func, tool_name)

        async def wrapped(*args: Any, **kwargs: Any) -> Any:
            result = func(*args, **kwargs)
            if inspect.isawaitable(result):
                result = await result
            return result

        wrapped.__name__ = tool_name
        wrapped.__doc__ = (func.__doc__ or "").rstrip()
        wrapped.__signature__ = inspect.signature(func)
        return wrapped

    shared.build_tool_wrapper = build_tool_wrapper
