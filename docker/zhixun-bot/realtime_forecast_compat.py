"""Compatibility helpers for realtime forecast plot URLs.

zhixun-core stores plots under its static ``/plots`` mount and may return a
relative URL.  The Feishu agent needs an absolute URL that it can render.
"""

from __future__ import annotations

from collections.abc import Mapping
from functools import wraps
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


def install(module: Any, base_url: str) -> None:
    """Wrap forecast tools so returned ``plot.url`` values are absolute."""

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
            return _absolute_url(result, base_url)

        wrapped._plot_url_compat = True
        setattr(module, name, wrapped)
