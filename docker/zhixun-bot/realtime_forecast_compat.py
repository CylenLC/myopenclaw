"""Compatibility helpers for realtime forecast models and plot delivery.

zhixun-core stores plots under its static ``/plots`` mount and may return a
relative URL. OpenClaw needs the absolute URL in a ``MEDIA:`` reply directive
so its Feishu adapter can upload the plot as a native image message.
"""

from __future__ import annotations

from functools import wraps
import inspect
import os
import re
from typing import Any


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


def _hide_plot_urls(value: Any, available_urls: set[str]) -> Any:
    if isinstance(value, list):
        return [_hide_plot_urls(item, available_urls) for item in value]
    if isinstance(value, dict):
        result = {}
        for key, item in value.items():
            if key == "plot" and isinstance(item, dict) and isinstance(item.get("url"), str):
                result[key] = {
                    child_key: child_value
                    for child_key, child_value in item.items()
                    if child_key not in {"url", "file_path"}
                }
                result[key]["media_attachment"] = (
                    "available" if item["url"] in available_urls else "unavailable"
                )
            else:
                result[key] = _hide_plot_urls(item, available_urls)
        return result
    return value


def _merge_model_runs(
    results: list[Any],
    errors: list[dict[str, str]],
    attempted_models: tuple[str, ...],
) -> Any:
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
    merged_payload["attempted_models"] = list(attempted_models)
    if hal:
        merged = dict(first)
        merged["data"] = merged_payload
        return merged
    return merged_payload


def _returned_models(value: Any) -> set[str]:
    payload = value.get("data") if isinstance(value, dict) else None
    if not isinstance(payload, dict):
        payload = value
    if not isinstance(payload, dict) or not isinstance(payload.get("results"), list):
        return set()
    return {
        str(row.get("model_name") or row.get("model") or "").strip().lower()
        for row in payload["results"]
        if isinstance(row, dict) and (row.get("model_name") or row.get("model"))
    }


def _error_models(value: Any) -> set[str]:
    payload = value.get("data") if isinstance(value, dict) else None
    if not isinstance(payload, dict):
        payload = value
    if not isinstance(payload, dict) or not isinstance(payload.get("errors"), list):
        return set()
    return {
        str(row.get("model_name") or row.get("model") or "").strip().lower()
        for row in payload["errors"]
        if isinstance(row, dict) and (row.get("model_name") or row.get("model"))
    }


def _add_media_attachments(value: Any) -> Any:
    entries = list(dict.fromkeys(_plot_entries(value)))
    available_urls = {url for _, url in entries}
    result = _hide_plot_urls(value, available_urls)
    if entries and isinstance(result, dict):
        result["media_attachments"] = [
            {
                "model_name": model,
                "media": url,
                "caption": f"{model} 降雨径流过程图",
                "delivery": "必须在最终回复中以独立一行 MEDIA:<media> 发送",
            }
            for model, url in entries
        ]
    return result


def install(module: Any, base_url: str) -> None:
    """Wrap forecast tools for explicit all-model runs and Feishu plot media."""

    def validate_model_name(value: str | None) -> str | None:
        if value is None or not value.strip():
            return None
        normalized = value.strip().lower()
        if normalized in {"all", "simplelstm", "dhf"} or re.fullmatch(
            r"sms3-[a-z0-9-]+", normalized
        ):
            return normalized
        raise ValueError(
            "model_name 仅支持 all、simplelstm、dhf 或 zhixun-core 已注册的 sms3-* 模型"
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
            if model.strip() and model.strip().lower() != "all"
        )
    )

    names = (
        "run_realtime_forecast",
        "get_latest_realtime_forecast",
        "run_realtime_forecast_compat",
        "get_latest_realtime_forecast_compat",
    )
    run_names = {"run_realtime_forecast", "run_realtime_forecast_compat"}
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
            run_all = requested_model is None or (
                isinstance(requested_model, str) and requested_model.strip().lower() == "all"
            )
            if __name in run_names and run_all:
                model_results = []
                model_errors = []
                for model in configured_models:
                    call_kwargs = dict(bound.arguments)
                    call_kwargs["model_name"] = model
                    try:
                        model_result = await __function(**call_kwargs)
                        model_results.append(model_result)
                        if (
                            model not in _returned_models(model_result)
                            and model not in _error_models(model_result)
                        ):
                            model_errors.append(
                                {
                                    "model_name": model,
                                    "error": "后端响应中既无该模型结果，也无该模型错误详情",
                                    "status": "missing",
                                }
                            )
                    except Exception as exc:
                        model_errors.append(
                            {"model_name": model, "error": str(exc), "status": "failed"}
                        )
                if not model_results:
                    raise RuntimeError(f"全部配置模型均执行失败: {model_errors}")
                result = _merge_model_runs(model_results, model_errors, configured_models)
            else:
                result = await __function(*args, **kwargs)
            return _add_media_attachments(_absolute_url(result, base_url))

        wrapped._plot_url_compat = True
        if name in run_names:
            base_doc = (wrapped.__doc__ or "").rstrip().replace(
                "model_name: simplelstm 或 dhf；留空运行全部可用模型。",
                "model_name: all、simplelstm、dhf 或已注册的 sms3-* 模型；"
                "全部模型必须显式传 all。",
            )
            wrapped.__doc__ = (
                "支持显式全模型调用：model_name='all' 会按 "
                "ZHIXUN_REALTIME_FORECAST_MODELS 逐一执行，并返回 attempted_models、"
                "逐模型错误和 media_attachments。\n\n"
                + base_doc
            )
        setattr(module, name, wrapped)
