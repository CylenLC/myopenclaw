"""Make basin-rainfall metric semantics explicit for the language model.

The upstream summary keeps two different values next to each other:
``average_rainfall`` is the basin-area average, while ``total_rainfall`` is
the sum of station totals. Preserve both fields for compatibility, but add
unambiguous aliases and a response contract so the latter cannot be reported
as basin areal rainfall.
"""

from __future__ import annotations

from functools import wraps
from typing import Any


def _annotate_summary(summary: Any) -> Any:
    if not isinstance(summary, dict):
        return summary

    annotated = dict(summary)
    if "average_rainfall" in annotated:
        annotated["basin_area_average_rainfall"] = annotated["average_rainfall"]
        annotated["basin_area_average_rainfall_unit"] = "mm"
    if "total_rainfall" in annotated:
        annotated["station_total_rainfall"] = annotated["total_rainfall"]
        annotated["station_total_rainfall_unit"] = "mm"
    annotated["rainfall_metric_contract"] = {
        "basin_area_rainfall_field": "average_rainfall",
        "basin_area_rainfall_alias": "basin_area_average_rainfall",
        "basin_area_rainfall_description": "流域面平均雨量，回答‘面雨量’时必须使用此值",
        "station_total_rainfall_field": "total_rainfall",
        "station_total_rainfall_alias": "station_total_rainfall",
        "station_total_rainfall_description": "各雨量站累计值之和，不是流域面雨量",
    }
    return annotated


def _annotate_result(result: Any) -> Any:
    if not isinstance(result, dict):
        return result
    normalized = dict(result)
    normalized["summary"] = _annotate_summary(result.get("summary"))
    normalized["rainfall_response_rule"] = (
        "‘面雨量’或‘流域平均雨量’只能读取 summary.average_rainfall（"
        "或 basin_area_average_rainfall）；summary.total_rainfall 仅表示各站累加值，"
        "必须明确标注为‘各站累加值’，不得当作流域面雨量。"
    )
    return normalized


def _scale_basin_statistics(result: Any) -> Any:
    """Convert the legacy basin station-sum statistics to area averages."""
    if not isinstance(result, dict) or str(result.get("scope") or "").lower() != "basin":
        return result
    try:
        station_count = int(result.get("station_count") or 0)
    except (TypeError, ValueError):
        station_count = 0
    if station_count <= 0:
        return result

    normalized = dict(result)

    def area_average(value: Any) -> Any:
        if not isinstance(value, (int, float)):
            return value
        return round(value / station_count, 2)

    for total_key in ("current_year_total", "compare_year_total", "average_total"):
        if total_key in normalized:
            normalized[f"station_{total_key}"] = normalized[total_key]
            normalized[total_key] = area_average(normalized[total_key])

    statistics = []
    for item in normalized.get("statistics", []):
        if not isinstance(item, dict):
            statistics.append(item)
            continue
        stat = dict(item)
        for value_key in ("current_year_value", "compare_year_value", "average_value"):
            if value_key in stat:
                stat[f"station_{value_key}"] = stat[value_key]
                stat[value_key] = area_average(stat[value_key])
        current = stat.get("current_year_value")
        average = stat.get("average_value")
        if isinstance(current, (int, float)) and isinstance(average, (int, float)):
            deviation = round(current - average, 2)
            stat["deviation_from_average"] = deviation
            stat["deviation_percentage"] = round(deviation / average * 100, 1) if average else 0
        statistics.append(stat)
    normalized["statistics"] = statistics
    normalized["rainfall_metric_contract"] = {
        "current_year_value": "流域面平均雨量（已按参与统计的雨量站数折算）",
        "station_current_year_value": "各雨量站累计值之和",
        "station_count": station_count,
        "warning": "不得把 station_current_year_value 或 station_current_year_total 当作流域面雨量",
    }
    return normalized


def install(module: Any) -> None:
    """Wrap basin rainfall tools before the unified MCP registers them."""
    summary_function = getattr(module, "get_basin_rainfall_summary", None)
    if summary_function is not None and not getattr(
        summary_function, "_rainfall_semantics_compat", False
    ):

        @wraps(summary_function)
        async def wrapped_summary(*args: Any, **kwargs: Any) -> Any:
            return _annotate_result(await summary_function(*args, **kwargs))

        wrapped_summary._rainfall_semantics_compat = True
        wrapped_summary.__doc__ = (
            "返回流域降雨汇总。注意：summary.average_rainfall 是流域面平均雨量；"
            "summary.total_rainfall 是各雨量站累计值之和，不能作为面雨量。\n\n"
            + (summary_function.__doc__ or "")
        )
        setattr(module, "get_basin_rainfall_summary", wrapped_summary)

    statistics_function = getattr(module, "get_rainfall_statistics", None)
    if statistics_function is not None and not getattr(
        statistics_function, "_rainfall_statistics_semantics_compat", False
    ):

        @wraps(statistics_function)
        async def wrapped_statistics(*args: Any, **kwargs: Any) -> Any:
            return _scale_basin_statistics(await statistics_function(*args, **kwargs))

        wrapped_statistics._rainfall_statistics_semantics_compat = True
        wrapped_statistics.__doc__ = (
            "流域统计中的 current_year_value、compare_year_value 和 average_value"
            "均表示流域面平均雨量；对应的 station_* 字段保留各站累加值。\n\n"
            + (statistics_function.__doc__ or "")
        )
        setattr(module, "get_rainfall_statistics", wrapped_statistics)


__all__ = ["install"]
