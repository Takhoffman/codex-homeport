from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import time
from typing import Callable


@dataclass(frozen=True)
class AppBranding:
    display_name: str
    bundle_name: str | None = None
    bundle_id_suffix: str = ".shim"


PatchAppBundle = Callable[[Path], int]
IsAppAsarPatched = Callable[[Path], bool]


def prepare_app_copy(
    source: Path,
    destination: Path,
    *,
    backup_dir: Path,
    replace: bool = False,
    branding: AppBranding | None = None,
    patch_app_bundle: PatchAppBundle,
) -> int:
    source = source.expanduser()
    destination = destination.expanduser()
    if not source.exists():
        print(f"Source app bundle not found at {source}.")
        return 1
    if source.resolve() == destination.resolve():
        print("Refusing to prepare an app copy in place; choose a separate destination.")
        return 1

    should_copy = replace or not destination.exists() or prepared_app_is_stale(source, destination, backup_dir=backup_dir)
    if should_copy and destination.exists():
        shutil.rmtree(destination)
    if should_copy and backup_dir.exists():
        shutil.rmtree(backup_dir)
    if should_copy:
        destination.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["ditto", str(source), str(destination)], check=True)
        print(f"Copied {source} to {destination}.")
    else:
        print(f"Prepared app copy is current: {destination}.")

    if branding is not None:
        apply_app_branding(destination, branding)
    code = patch_app_bundle(destination)
    if code == 0:
        write_prepared_app_metadata(source, destination, backup_dir=backup_dir)
    return code


def prepared_app_status_payload(
    source: Path,
    destination: Path,
    *,
    backup_dir: Path,
    is_patched: IsAppAsarPatched,
) -> dict[str, object]:
    source = source.expanduser()
    destination = destination.expanduser()
    source_exists = source.exists()
    destination_exists = destination.exists()
    source_signature = safe_app_source_signature(source) if source_exists else None
    destination_signature = safe_app_source_signature(destination) if destination_exists else None
    destination_asar = destination / "Contents/Resources/app.asar"
    patched = destination_asar.exists() and is_patched(destination_asar)
    metadata = read_prepared_app_metadata(backup_dir=backup_dir) if destination_exists else None
    stale = True
    if source_exists and destination_exists:
        stale = prepared_app_is_stale(source, destination, backup_dir=backup_dir)
    return {
        "source_path": str(source),
        "destination_path": str(destination),
        "source_exists": source_exists,
        "destination_exists": destination_exists,
        "source": source_signature,
        "destination": destination_signature,
        "patched": patched,
        "stale": stale,
        "metadata": metadata,
    }


def prepared_app_is_stale(source: Path, destination: Path, *, backup_dir: Path) -> bool:
    if not destination.exists():
        return True
    metadata = read_prepared_app_metadata(backup_dir=backup_dir)
    if not metadata:
        return True
    try:
        source_signature = app_source_signature(source)
    except OSError:
        return True
    return metadata.get("source") != source_signature


def write_prepared_app_metadata(source: Path, destination: Path, *, backup_dir: Path) -> None:
    metadata_path = prepared_app_metadata_path(backup_dir)
    metadata_path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "source": app_source_signature(source),
        "destination": app_source_signature(destination),
        "prepared_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    metadata_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def read_prepared_app_metadata(*, backup_dir: Path) -> dict[str, object] | None:
    metadata_path = prepared_app_metadata_path(backup_dir)
    try:
        data = json.loads(metadata_path.read_text())
    except (OSError, json.JSONDecodeError):
        return None
    return data if isinstance(data, dict) else None


def prepared_app_metadata_path(backup_dir: Path) -> Path:
    return backup_dir / "source.json"


def apply_app_branding(codex_app: Path, branding: AppBranding) -> None:
    info_plist = codex_app / "Contents/Info.plist"
    if not info_plist.exists():
        return
    data = plistlib.loads(info_plist.read_bytes())
    bundle_name = branding.bundle_name or branding.display_name
    data["CFBundleName"] = bundle_name
    data["CFBundleDisplayName"] = branding.display_name
    bundle_id = str(data.get("CFBundleIdentifier") or "com.openai.codex")
    suffix = branding.bundle_id_suffix
    if suffix and not bundle_id.endswith(suffix):
        data["CFBundleIdentifier"] = f"{bundle_id}{suffix}"
    info_plist.write_bytes(plistlib.dumps(data))


def safe_app_source_signature(codex_app: Path) -> dict[str, object] | None:
    try:
        return app_source_signature(codex_app)
    except OSError:
        return None


def app_source_signature(codex_app: Path) -> dict[str, object]:
    app_asar = codex_app / "Contents/Resources/app.asar"
    info_plist = codex_app / "Contents/Info.plist"
    info: dict[str, object] = {}
    try:
        data = plistlib.loads(info_plist.read_bytes())
        for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion"):
            value = data.get(key)
            if value is not None:
                info[key] = value
    except OSError:
        pass
    return {
        "path": str(codex_app),
        "app_asar_sha256": app_asar_hash(app_asar),
        "info": info,
    }


def app_asar_hash(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def app_patch_backup_dir(codex_app: Path, *, runtime_dir: Path, root_apps: tuple[Path, ...] = ()) -> Path:
    if codex_app in root_apps:
        return runtime_dir
    digest = hashlib.sha1(str(codex_app).encode()).hexdigest()[:12]
    return runtime_dir / "app-patches" / digest
