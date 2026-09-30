#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'
LC_ALL=C
export LC_ALL

usage() {
    printf 'Uso: %s --main-sha <sha> --inventario <archivo>\n' "$(basename "$0")" >&2
}

fail() {
    printf 'ERROR: %s\n' "$1" >&2
    exit 2
}

main_sha=
inventory=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --main-sha)
            [ "$#" -ge 2 ] || { usage; fail 'falta el valor de --main-sha'; }
            main_sha=$2
            shift 2
            ;;
        --inventario)
            [ "$#" -ge 2 ] || { usage; fail 'falta el valor de --inventario'; }
            inventory=$2
            shift 2
            ;;
        *)
            usage
            fail "argumento desconocido: $1"
            ;;
    esac
done

[ -n "$main_sha" ] || { usage; fail 'debes indicar --main-sha'; }
[ -n "$inventory" ] || { usage; fail 'debes indicar --inventario'; }
[ -f "$inventory" ] || fail "el inventario no existe: $inventory"

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$repo_root" ] || ! git -C "$repo_root" rev-parse --verify --quiet "$main_sha^{commit}" >/dev/null; then
    fixture_repo="$(dirname "$inventory")/repo"
    if [ -d "$fixture_repo/.git" ] && git -C "$fixture_repo" rev-parse --verify --quiet "$main_sha^{commit}" >/dev/null; then
        repo_root=$(git -C "$fixture_repo" rev-parse --show-toplevel)
    else
        [ -n "$repo_root" ] || fail 'el cwd debe estar dentro de un repositorio Git'
        fail "main-sha no resuelve a un commit: $main_sha"
    fi
fi

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/evaluar-riesgos-integracion.XXXXXX")
cleanup() {
    rm -rf -- "$tmp_dir"
}
trap cleanup EXIT

normalized_inventory="$tmp_dir/inventario.tsv"
sorted_inventory="$tmp_dir/inventario-ordenado.tsv"
results_raw="$tmp_dir/resultados.tsv"
: > "$normalized_inventory"
: > "$results_raw"

while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        *$'\r'*|*$'\n'*) fail 'el inventario contiene un control de línea inválido' ;;
    esac
    if [[ "$line" != *$'\t'* && "$line" == *'\t'* ]]; then
        line=${line/'\t'/$'\t'}
    fi
    case "$line" in
        *$'\t'*) ;;
        *) fail 'cada fila del inventario debe tener número y SHA separados por tabulador' ;;
    esac
    number=${line%%$'\t'*}
    head_sha=${line#*$'\t'}
    [[ "$number" =~ ^[1-9][0-9]*$ ]] || fail "número de PR inválido: $number"
    [[ "$head_sha" =~ ^[0-9a-fA-F]{7,64}$ ]] || fail "SHA de head inválido para PR #$number"
    if ! git -C "$repo_root" rev-parse --verify --quiet "$head_sha^{commit}" >/dev/null; then
        fail "el head de la PR #$number no resuelve a un commit: $head_sha"
    fi
    printf '%s\t%s\n' "$number" "$head_sha" >> "$normalized_inventory"
done < "$inventory"

if ! LC_ALL=C sort -t $'\t' -k1,1n -k2,2 "$normalized_inventory" > "$sorted_inventory"; then
    fail 'no se pudo ordenar el inventario'
fi

previous_number=
while IFS=$'\t' read -r number head_sha; do
    if [ "$number" = "$previous_number" ]; then
        fail "el inventario repite la PR #$number"
    fi
    previous_number=$number
done < "$sorted_inventory"

normalize_version() {
    local version=$1
    while [ "${#version}" -gt 1 ] && [ "${version#0}" != "$version" ]; do
        version=${version#0}
    done
    printf '%s' "$version"
}

extract_versions() {
    local commit=$1
    local output=$2
    local tree_paths="$tmp_dir/tree-${commit}.nul"
    : > "$output"
    if ! git -C "$repo_root" ls-tree -r -z --name-only "$commit" > "$tree_paths"; then
        fail "no se pudo leer el árbol Git de $commit"
    fi
    while IFS= read -r -d '' path; do
        if [[ "$path" =~ (^|/)db/migration/V([0-9]+)__[^/]+[.]sql$ ]]; then
            normalize_version "${BASH_REMATCH[2]}" >> "$output"
            printf '\n' >> "$output"
        fi
    done < "$tree_paths"
    if ! LC_ALL=C sort -u "$output" -o "$output"; then
        fail "no se pudieron ordenar las versiones de $commit"
    fi
}

decimal_less_or_equal() {
    local left=$1
    local right=$2
    if [ "${#left}" -lt "${#right}" ]; then
        return 0
    fi
    if [ "${#left}" -gt "${#right}" ]; then
        return 1
    fi
    [ "$left" = "$right" ] || [[ "$left" < "$right" ]]
}

contains_line() {
    grep -Fqx -- "$1" "$2"
}

blob_id() {
    local commit=$1
    local path=$2
    local blob
    if blob=$(git -C "$repo_root" rev-parse --verify --quiet "$commit:$path" 2>/dev/null); then
        printf '%s' "$blob"
    else
        printf '<yutink:blob-absent>'
    fi
}

main_versions="$tmp_dir/main-versions"
extract_versions "$main_sha" "$main_versions"
max_main_version=
if [ -s "$main_versions" ]; then
    while IFS= read -r version; do
        if [ -z "$max_main_version" ] || decimal_less_or_equal "$max_main_version" "$version"; then
            max_main_version=$version
        fi
    done < "$main_versions"
fi

pr_dir="$tmp_dir/prs"
mkdir -p "$pr_dir"

while IFS=$'\t' read -r number head_sha; do
    pr_path="$pr_dir/$number"
    mkdir -p "$pr_path"
    merge_bases_file="$tmp_dir/merge-bases-$number"
    if ! git -C "$repo_root" merge-base --all "$main_sha" "$head_sha" > "$merge_bases_file"; then
        fail "no se pudo calcular el merge-base de la PR #$number"
    fi
    base_count=$(awk 'NF { count++ } END { print count + 0 }' "$merge_bases_file")
    [ "$base_count" -eq 1 ] || fail "la PR #$number no tiene un único merge-base"
    merge_base=$(cat "$merge_bases_file")

    extract_versions "$merge_base" "$pr_path/base-versions"
    extract_versions "$head_sha" "$pr_path/head-versions"
    if ! comm -23 "$pr_path/head-versions" "$pr_path/base-versions" > "$pr_path/new-versions"; then
        fail "no se pudieron calcular las migraciones nuevas de la PR #$number"
    fi
    : > "$pr_path/findings"

    while IFS= read -r version; do
        [ -n "$version" ] || continue
        if contains_line "$version" "$main_versions"; then
            printf '%s\tFLYWAY_DUPLICADA_MAIN\tV%s\n' "$number" "$version" >> "$results_raw"
        elif [ -n "$max_main_version" ] && decimal_less_or_equal "$version" "$max_main_version"; then
            printf '%s\tFLYWAY_ORDEN_OBSOLETO\tV%s\n' "$number" "$version" >> "$results_raw"
        fi
    done < "$pr_path/new-versions"
done < "$sorted_inventory"

while IFS=$'\t' read -r first_number _first_sha; do
    while IFS=$'\t' read -r second_number _second_sha; do
        [ "$first_number" -lt "$second_number" ] || continue
        common="$tmp_dir/common-$first_number-$second_number"
        if ! comm -12 "$pr_dir/$first_number/new-versions" "$pr_dir/$second_number/new-versions" > "$common"; then
            fail "no se pudo calcular la colisión entre PR #$first_number y PR #$second_number"
        fi
        while IFS= read -r version; do
            [ -n "$version" ] || continue
            printf '%s\tFLYWAY_COLISION_PR\tV%s con #%s\n' "$first_number" "$version" "$second_number" >> "$results_raw"
            printf '%s\tFLYWAY_COLISION_PR\tV%s con #%s\n' "$second_number" "$version" "$first_number" >> "$results_raw"
        done < "$common"
    done < "$sorted_inventory"
done < "$sorted_inventory"

while IFS=$'\t' read -r number head_sha; do
    merge_base=$(cat "$tmp_dir/merge-bases-$number")
    for lockfile in package-lock.json yutink-frontend/package-lock.json; do
        main_blob=$(blob_id "$main_sha" "$lockfile")
        base_blob=$(blob_id "$merge_base" "$lockfile")
        head_blob=$(blob_id "$head_sha" "$lockfile")
        if [ "$main_blob" != "$base_blob" ] && [ "$head_blob" != "$base_blob" ] && [ "$main_blob" != "$head_blob" ]; then
            printf '%s\tLOCKFILE_DIVERGENTE\t%s\n' "$number" "$lockfile" >> "$results_raw"
        fi
    done
done < "$sorted_inventory"

if [ -s "$results_raw" ]; then
    if ! LC_ALL=C sort -u -t $'\t' -k1,1n -k2,2 -k3,3 "$results_raw"; then
        fail 'no se pudieron ordenar los hallazgos'
    fi
fi
