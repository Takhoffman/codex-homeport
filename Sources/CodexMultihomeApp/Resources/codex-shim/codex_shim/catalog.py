from __future__ import annotations

from datetime import datetime, timezone
import json
from pathlib import Path

from . import router as router_module
from .settings import (
    CHATGPT_MODEL_SLUG,
    PROVIDER_NAME,
    ShimModel,
    available_model_slugs,
    chatgpt_passthrough_available,
    default_model_slug,
    load_chatgpt_passthrough_catalog_models,
    usable_byok_models,
)
from .cursor_passthrough import cursor_catalog_entry, cursor_passthrough_available


PLAN_TIERS = ["free", "plus", "pro", "team", "business", "enterprise"]


def catalog_entry(model: ShimModel, *, is_default: bool = False) -> dict:
    context = model.max_context_limit or _default_context(model)
    compact = max(8_000, int(context * 0.8))
    truncation = min(64_000, max(8_000, int(context * 0.32)))
    levels = _reasoning_levels(model)
    reasoning = model.default_reasoning_level if model.default_reasoning_level in levels else _reasoning_effort(model, levels)
    entry = {
        "slug": model.slug,
        "display_name": model.display_name,
        "description": f"{model.display_name} via local Codex shim.",
        "context_window": context,
        "max_context_window": context,
        "auto_compact_token_limit": compact,
        "truncation_policy": {"mode": "tokens", "limit": truncation},
        "default_reasoning_level": reasoning,
        "supported_reasoning_levels": [_reasoning_level_entry(level) for level in levels],
        "default_reasoning_summary": "none",
        "reasoning_summary_format": "none",
        "supports_reasoning_summaries": False,
        "default_verbosity": "low",
        "support_verbosity": False,
        "apply_patch_tool_type": "freeform",
        "web_search_tool_type": "text_and_image",
        "supports_search_tool": False,
        "supports_parallel_tool_calls": True,
        "experimental_supported_tools": [],
        "input_modalities": ["text"] if model.no_image_support else ["text", "image"],
        "supports_image_detail_original": not model.no_image_support,
        "shell_type": "shell_command",
        "visibility": "list",
        "minimal_client_version": "0.0.1",
        "supported_in_api": True,
        "availability_nux": None,
        "upgrade": None,
        "priority": max(1, 1000 - model.index),
        "prefer_websockets": False,
        "available_in_plans": PLAN_TIERS,
        "base_instructions": f"You are Codex running on {model.display_name} through a local all-model shim.",
        "model_messages": {
            "instructions_template": (
                f"You are Codex running on {model.display_name} through a local all-model shim. "
                "Be a helpful, direct coding collaborator."
            ),
            "instructions_variables": {"model_name": model.display_name},
        },
    }
    _add_desktop_model_fields(entry)
    if is_default:
        entry["isDefault"] = True
    return entry


def chatgpt_passthrough_entries(*, default_slug: str | None = None) -> list[dict]:
    """Catalog entries for GPT models routed through ChatGPT passthrough."""
    entries: list[dict] = []
    for raw in load_chatgpt_passthrough_catalog_models():
        entry = dict(raw)
        entry["visibility"] = "list"
        entry.setdefault("available_in_plans", PLAN_TIERS)
        entry.setdefault("minimal_client_version", "0.0.1")
        entry.setdefault("supported_in_api", True)
        _add_desktop_model_fields(entry)
        if entry.get("slug") == default_slug:
            entry["isDefault"] = True
        else:
            entry.pop("isDefault", None)
        if entry.get("slug") == CHATGPT_MODEL_SLUG:
            entry["priority"] = max(int(entry.get("priority") or 0), 10000)
        entries.append(entry)
    return entries


def chatgpt_passthrough_entry() -> dict:
    """Catalog entry for the default GPT-5.5 ChatGPT passthrough model."""
    for entry in chatgpt_passthrough_entries():
        if entry.get("slug") == CHATGPT_MODEL_SLUG:
            return entry
    return chatgpt_passthrough_entries()[0]


def catalog_entries(models: list[ShimModel], router_config=None, default_slug: str | None = None) -> list[dict]:
    if default_slug is None:
        try:
            default_slug = default_model_slug(models)
        except ValueError:
            default_slug = None
    entries: list[dict] = []
    if router_config is not None and router_module.router_is_active(router_config, available_model_slugs(models)):
        entry = router_module.router_catalog_entry(router_config)
        _add_desktop_model_fields(entry)
        if entry.get("slug") == default_slug:
            entry["isDefault"] = True
        entries.append(entry)
    if chatgpt_passthrough_available():
        entries.extend(chatgpt_passthrough_entries(default_slug=default_slug))
    if cursor_passthrough_available():
        entry = cursor_catalog_entry()
        _add_desktop_model_fields(entry)
        if entry.get("slug") == default_slug:
            entry["isDefault"] = True
        else:
            entry.pop("isDefault", None)
        entries.append(entry)
    entries.extend(catalog_entry(model, is_default=model.slug == default_slug) for model in usable_byok_models(models))
    return entries


def write_catalog(models: list[ShimModel], path: Path, router_config=None, default_slug: str | None = None) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    entries = catalog_entries(models, router_config=router_config, default_slug=default_slug)
    payload = {"models": entries}
    path.write_text(json.dumps(payload, indent=2, sort_keys=False) + "\n")
    return path


def write_models_cache(models: list[ShimModel], path: Path, router_config=None, default_slug: str | None = None) -> Path:
    """Write Codex Desktop's per-home model cache from the shim catalog."""
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "fetched_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "etag": "codex-shim",
        "client_version": "codex-shim",
        "models": catalog_entries(models, router_config=router_config, default_slug=default_slug),
    }
    path.write_text(json.dumps(payload, indent=2, sort_keys=False) + "\n")
    return path


def write_config(models: list[ShimModel], path: Path, catalog_path: Path, port: int) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        default_slug = default_model_slug(models)
    except ValueError as exc:
        raise SystemExit(str(exc)) from exc
    text = f'''# Generated by codex-shim. This file is opt-in and is not ~/.codex/config.toml.
model = "{_toml_escape(default_slug)}"
model_provider = "{PROVIDER_NAME}"
model_catalog_json = "{_toml_escape(str(catalog_path))}"

[model_providers.{PROVIDER_NAME}]
name = "Codex Shim"
base_url = "http://127.0.0.1:{port}/v1"
wire_api = "responses"
experimental_bearer_token = "dummy"
request_max_retries = 3
stream_max_retries = 3
stream_idle_timeout_ms = 600000
'''
    path.write_text(text)
    return path


def codex_config_overrides(catalog_path: Path, default_slug: str, port: int) -> list[str]:
    return [
        f'model="{_toml_escape(default_slug)}"',
        f'model_provider="{PROVIDER_NAME}"',
        f'model_catalog_json="{_toml_escape(str(catalog_path))}"',
        f'model_providers.{PROVIDER_NAME}.name="Codex Shim"',
        f'model_providers.{PROVIDER_NAME}.base_url="http://127.0.0.1:{port}/v1"',
        f'model_providers.{PROVIDER_NAME}.wire_api="responses"',
        f'model_providers.{PROVIDER_NAME}.experimental_bearer_token="dummy"',
        f'model_providers.{PROVIDER_NAME}.request_max_retries=3',
        f'model_providers.{PROVIDER_NAME}.stream_max_retries=3',
        f'model_providers.{PROVIDER_NAME}.stream_idle_timeout_ms=600000',
    ]


def _default_context(model: ShimModel) -> int:
    lower = f"{model.model} {model.display_name}".lower()
    if "claude" in lower:
        return 200_000
    if "gpt-5" in lower:
        return 400_000
    if "gemini" in lower:
        return 1_000_000
    return 128_000


def _reasoning_levels(model: ShimModel) -> tuple[str, ...]:
    return model.reasoning_levels or ("low", "medium", "high", "xhigh")


def _reasoning_level_entry(level: str) -> dict[str, str]:
    descriptions = {
        "minimal": "Minimal reasoning",
        "low": "Faster, lighter reasoning",
        "medium": "Balanced speed and reasoning",
        "high": "Deeper reasoning",
        "xhigh": "Maximum reasoning where supported",
    }
    return {"effort": level, "description": descriptions.get(level, f"{level.title()} reasoning")}


def _add_desktop_model_fields(entry: dict) -> None:
    """Add the camelCase model shape consumed by Codex Desktop's composer."""
    slug = entry.get("slug")
    display_name = entry.get("display_name")
    if slug is not None:
        entry.setdefault("model", slug)
    if display_name is not None:
        entry.setdefault("displayName", display_name)
    entry.setdefault("hidden", entry.get("visibility") == "hidden")

    default_reasoning = entry.get("default_reasoning_level")
    if default_reasoning is not None:
        entry.setdefault("defaultReasoningEffort", default_reasoning)

    if "supportedReasoningEfforts" not in entry:
        levels = entry.get("supported_reasoning_levels")
        if isinstance(levels, list):
            efforts = []
            for level in levels:
                if not isinstance(level, dict):
                    continue
                effort = level.get("effort")
                if effort is None:
                    continue
                efforts.append(
                    {
                        "reasoningEffort": effort,
                        "description": str(level.get("description") or f"{effort} reasoning"),
                    }
                )
            entry["supportedReasoningEfforts"] = efforts


def _reasoning_effort(model: ShimModel, levels: tuple[str, ...] | None = None) -> str:
    levels = levels or _reasoning_levels(model)
    lower = model.display_name.lower()
    if ("xhigh" in lower or "x-high" in lower) and "xhigh" in levels:
        return "xhigh"
    if "high" in lower and "high" in levels:
        return "high"
    if "medium" in lower and "medium" in levels:
        return "medium"
    if "low" in lower and "low" in levels:
        return "low"
    return "medium" if "medium" in levels else levels[0]


def _toml_escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')
