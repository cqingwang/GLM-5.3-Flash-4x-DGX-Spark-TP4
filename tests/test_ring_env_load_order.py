from pathlib import Path
import subprocess


MODULE_ROOT = Path(__file__).resolve().parents[1]


def test_profile_loads_after_managed_ring_environment():
    environment_template = (MODULE_ROOT / ".env.example").read_text()
    launcher = (MODULE_ROOT / "start.sh").read_text()

    assert "source profiles/current.env" not in environment_template
    assert launcher.index('source "$ENV_FILE"') < launcher.index("source profiles/current.env")

    result = subprocess.run(
        ["bash", "-c", 'set -u; PORT=8888; IB_HCA=rocep1s0f0; source profiles/current.env; printf "%s" "$PORT"'],
        cwd=MODULE_ROOT,
        capture_output=True,
        text=True,
        check=True,
    )
    assert result.stdout == "8888"


def test_profile_binds_api_to_management_network():
    result = subprocess.run(
        ["bash", "-c", 'source profiles/current.env; printf "%s" "$HOST_BIND"'],
        cwd=MODULE_ROOT,
        capture_output=True,
        text=True,
        check=True,
    )
    assert result.stdout == "0.0.0.0"


def test_ring_shipper_ssh_does_not_consume_later_route_rows():
    model_shipper = (MODULE_ROOT / "scripts/ship_models_ring.sh").read_text()
    image_shipper = (MODULE_ROOT / "scripts/ship_image_ring.sh").read_text()

    assert 'ssh -n -o BatchMode=yes -o ConnectTimeout=15 "$REMOTE_USER@$source_management" "$remote_command"' in model_shipper
    assert 'ssh -n -o BatchMode=yes "$REMOTE_USER@$target_management"' in model_shipper
    assert '"docker load -i \'$REMOTE_ARCHIVE\' >/dev/null" </dev/null' in image_shipper
    assert 'ssh -n -o BatchMode=yes -o ConnectTimeout=15 "$REMOTE_USER@$source_management" "$remote_command"' in image_shipper


def test_first_deployment_stop_uses_launcher_source_before_overlay_sync():
    launcher = (MODULE_ROOT / "start.sh").read_text()

    assert 'SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' in launcher
    assert 'python3 $SCRIPT_DIR/scripts/stop_preserving.py --root $OVERLAY_REMOTE' in launcher
