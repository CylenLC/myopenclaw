"""Compatibility helpers for realtime forecast plot URLs.

zhixun-core stores plots under its static ``/plots`` mount and may return a
relative URL.  The Feishu agent needs an absolute URL that it can render.
"""

from __future__ import annotations

from functools import wraps
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


def _plot_urls(value: Any) -> list[str]:
    if isinstance(value, dict):
        urls = []
        for key, item in value.items():
            if key in {"url", "plot_url", "image_url"} and isinstance(item, str):
                if item.startswith(("http://", "https://")) and item.lower().split("?", 1)[0].endswith(
                    (".png", ".jpg", ".jpeg", ".webp", ".gif")
                ):
                    urls.append(item)
            else:
                urls.extend(_plot_urls(item))
        return urls
    if isinstance(value, list):
        return [url for item in value for url in _plot_urls(item)]
    return []


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
        async def wrapped(*args: Any, __function=function, **kwargs: Any) -> Any:
            result = await __function(*args, **kwargs)
            normalized = _absolute_url(result, base_url)
            images = []
            async with httpx.AsyncClient(timeout=30) as client:
                for index, url in enumerate(dict.fromkeys(_plot_urls(normalized)), start=1):
                    try:
                        response = await client.get(url)
                        response.raise_for_status()
                        images.append(
                            (
                                TextContent(
                                    type="text",
                                    text=f"降雨径流过程图 {index}: {url}",
                                ),
                                Image(data=response.content, format="png"),
                            )
                        )
                    except httpx.HTTPError:
                        # Keep the URL in the JSON result if image retrieval fails.
                        continue
            return (
                [normalized, *(block for pair in images for block in pair)]
                if images
                else normalized
            )

        wrapped._plot_url_compat = True
        setattr(module, name, wrapped)
