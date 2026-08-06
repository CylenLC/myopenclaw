"""Start the upstream Water MCP with local compatibility fixes."""

import argparse
import asyncio

import utils_xz
from briefing_compat import install as install_briefing_compat
from related_page_compat import install as install_related_pages
from realtime_forecast_compat import (
    install as install_realtime_forecast_compat,
    install_all_points_contract,
)
from zhixun_core_v2_compat import install


install(utils_xz)

import get_url_server
import mcp_server_briefing
import mcp_server_realtime_forecast
import mcp_server_xz

# Patch functions before mcp_server_unified imports and registers them.
install_related_pages(mcp_server_xz, get_url_server)
install_all_points_contract(
    mcp_server_xz,
    {
        "get_station_timeseries",
        "get_reservoir_profile",
        "get_river_historical_comparison",
        "get_basin_rainfall_summary",
        "get_basin_rainfall_forecast",
        "get_basin_rainfall_complete",
        "get_rainfall_statistics",
    },
)
install_briefing_compat(mcp_server_briefing)
install_realtime_forecast_compat(
    mcp_server_realtime_forecast,
    mcp_server_realtime_forecast.REALTIME_FORECAST_BASE_URL,
)

import mcp_server_unified


mcp_server_unified._register_wrapped_tool(
    "run_all_realtime_forecasts",
    mcp_server_realtime_forecast.run_all_realtime_forecasts,
)


def main() -> None:
    parser = argparse.ArgumentParser(description="Unified Water MCP Server")
    parser.add_argument(
        "transport",
        nargs="?",
        default="stdio",
        choices=["stdio", "sse", "streamable-http"],
    )
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=18200)
    args = parser.parse_args()

    mcp = mcp_server_unified.mcp
    if args.transport != "stdio":
        mcp.settings.host = args.host
        mcp.settings.port = args.port

    if args.transport == "sse":
        import uvicorn
        from starlette.middleware.cors import CORSMiddleware

        app = mcp.sse_app()
        app.add_middleware(
            CORSMiddleware,
            allow_origins=["*"],
            allow_credentials=True,
            allow_methods=["*"],
            allow_headers=["*"],
        )
        config = uvicorn.Config(
            app,
            host=args.host,
            port=args.port,
            log_level="info",
        )
        asyncio.run(uvicorn.Server(config).serve())
    else:
        mcp.run(transport=args.transport)


if __name__ == "__main__":
    main()
