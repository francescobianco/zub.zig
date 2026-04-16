#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZUB_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALL_SCRIPT="$ZUB_DIR/docs/install.sh"

DOCKERFILES=(
    "$SCRIPT_DIR/ubuntu/Dockerfile"
    "$SCRIPT_DIR/debian/Dockerfile"
    "$SCRIPT_DIR/alpine/Dockerfile"
)

cleanup() {
    for container in "${CONTAINERS[@]:-}"; do
        [ -n "$container" ] && docker rm -f "$container" 2>/dev/null || true
    done
}
trap cleanup EXIT

CONTAINERS=()

for dockerfile in "${DOCKERFILES[@]}"; do
    name="$(basename "$(dirname "$dockerfile")")"
    echo "=== Testing on $name ==="

    image="zub-test-$name:latest"
    docker build -t "$image" -f "$dockerfile" "$(dirname "$dockerfile")"

    container_id=$(docker run -dit --rm "$image" bash)
    CONTAINERS+=("$container_id")

    echo "Copying install script..."
    docker cp "$INSTALL_SCRIPT" "$container_id:/home/testuser/install.sh"

    echo "Running install script..."
    if docker exec "$container_id" bash /home/testuser/install.sh; then
        echo "✓ $name: install successful"

        if docker exec "$container_id" test -x "$HOME/.local/bin/zub"; then
            echo "✓ $name: zub binary exists and is executable"
        else
            echo "✗ $name: zub binary not found or not executable"
            exit 1
        fi
    else
        echo "✗ $name: install failed"
        exit 1
    fi

    echo
done

echo "=== All tests passed ==="