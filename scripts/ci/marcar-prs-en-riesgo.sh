#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'
LC_ALL=C
export LC_ALL

MARKER='<!-- yutink:risk-integration:v1 -->'
LABEL="${RIESGO_ETIQUETA:-riesgo-integracion}"
LABEL_SEGMENT=''
MAX_MUTATIONS="${RIESGO_MAX_MUTACIONES_POR_MINUTO:-50}"
TEST_WAIT="${RIESGO_ESPERA_SEGUNDOS_TEST:-}"
REPOSITORY="${GITHUB_REPOSITORY:-}"
MAIN_SHA="${GITHUB_SHA:-}"

fail() {
    printf 'marcar-prs-en-riesgo: %s\n' "$1" >&2
    return 1
}

warning() {
    printf '::warning::marcar-prs-en-riesgo: %s\n' "$1" >&2
}

require_environment() {
    [ -n "${GH_TOKEN:-}" ] || { fail 'GH_TOKEN es obligatorio.'; return 1; }
    [ -n "$REPOSITORY" ] || { fail 'GITHUB_REPOSITORY es obligatorio.'; return 1; }
    [ -n "$MAIN_SHA" ] || { fail 'GITHUB_SHA es obligatorio.'; return 1; }
    [[ "$REPOSITORY" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || {
        fail 'GITHUB_REPOSITORY debe tener formato owner/repository.'
        return 1
    }
    [[ "$MAIN_SHA" =~ ^[0-9a-fA-F]{7,64}$ ]] || {
        fail 'GITHUB_SHA no es un SHA hexadecimal válido.'
        return 1
    }
    [[ "$LABEL" =~ ^[^[:cntrl:]]{1,50}$ ]] || {
        fail 'RIESGO_ETIQUETA contiene caracteres no permitidos.'
        return 1
    }
    [[ "$MAX_MUTATIONS" =~ ^[1-9][0-9]*$ ]] || {
        fail 'RIESGO_MAX_MUTACIONES_POR_MINUTO debe ser un entero positivo.'
        return 1
    }
    if [ -n "$TEST_WAIT" ] && ! [[ "$TEST_WAIT" =~ ^[0-9]+$ ]]; then
        fail 'RIESGO_ESPERA_SEGUNDOS_TEST debe ser un entero no negativo.'
        return 1
    fi
    command -v gh >/dev/null 2>&1 || { fail 'gh no está disponible en PATH.'; return 1; }
    command -v jq >/dev/null 2>&1 || { fail 'jq no está disponible en PATH.'; return 1; }
    if ! LABEL_SEGMENT=$(jq -rn --arg n "$LABEL" '$n|@uri'); then
        fail 'no se pudo codificar RIESGO_ETIQUETA como segmento URI.'
        return 1
    fi
    git remote get-url origin >/dev/null 2>&1 || {
        fail 'el repositorio no tiene un remoto origin.'
        return 1
    }
    git rev-parse --verify --quiet "$MAIN_SHA^{commit}" >/dev/null || {
        fail "GITHUB_SHA no resuelve a un commit local: $MAIN_SHA"
        return 1
    }
}

tmp_dir=''
cleanup() {
    if [ -n "$tmp_dir" ] && [ -d "$tmp_dir" ]; then
        find "$tmp_dir" -mindepth 1 -delete
        rmdir "$tmp_dir"
    fi
}
trap cleanup EXIT

origin_main_sha() {
    local remote_lines
    remote_lines=$(git ls-remote --exit-code origin refs/heads/main 2>/dev/null) || return 1
    remote_lines="${remote_lines%%$'\n'*}"
    printf '%s' "${remote_lines%%$'\t'*}"
}

check_origin_main() {
    local remote_sha
    if ! remote_sha=$(origin_main_sha); then
        fail 'no se pudo leer refs/heads/main desde origin.'
        return 1
    fi
    if [ "$remote_sha" != "$MAIN_SHA" ]; then
        fail "origin/main ($remote_sha) no coincide con GITHUB_SHA ($MAIN_SHA)."
        return 1
    fi
}

list_open_prs() {
    local raw_file="$1" combined_file="$2" endpoint
    endpoint="repos/$REPOSITORY/pulls?state=open&base=main&per_page=100"
    if ! gh api --paginate "$endpoint" >"$raw_file" 2>"$tmp_dir/gh-list.err"; then
        cat "$tmp_dir/gh-list.err" >&2
        fail 'no se pudo listar o paginar el inventario completo de PRs.'
        return 1
    fi
    if ! jq -s 'if length == 0 then [] else add end' "$raw_file" >"$combined_file"; then
        fail 'la respuesta paginada de PRs no es JSON válido.'
        return 1
    fi
    if ! jq -e 'type == "array"' "$combined_file" >/dev/null; then
        fail 'la respuesta de PRs no tiene forma de arreglo.'
        return 1
    fi
    if ! jq -e '
        all(.[];
            type == "object"
            and (.number | type) == "number"
            and (.number | floor) == .number
            and (.state | type) == "string"
            and .state == "open"
            and (.base | type) == "object"
            and (.base.ref | type) == "string"
            and .base.ref == "main"
            and (.head | type) == "object"
            and (.head.sha | type) == "string"
        )
    ' "$combined_file" >/dev/null; then
        fail 'el inventario de PRs contiene una entrada incompleta o fuera de main.'
        return 1
    fi
    if ! jq -e '([.[].number] | length) == ([.[].number] | unique | length)' "$combined_file" >/dev/null; then
        fail 'el inventario de PRs contiene números duplicados.'
        return 1
    fi
}

fetch_heads_and_inventory() {
    local prs_file="$1" inventory_file="$2" source_file="$tmp_dir/inventory-source.tsv" number head_sha ref_sha local_sha fetch_log
    if ! jq -r '.[] | [(.number | floor | tostring), .head.sha] | @tsv' "$prs_file" >"$source_file"; then
        fail 'no se pudo construir el inventario de heads de PRs.'
        return 1
    fi
    : >"$inventory_file"
    while IFS=$'\t' read -r number head_sha; do
        [ -n "$number" ] || continue
        if ! [[ "$head_sha" =~ ^[0-9a-fA-F]{7,64}$ ]]; then
            fail "el head de la PR #$number no es un SHA válido."
            return 1
        fi
        fetch_log="$tmp_dir/fetch-$number.log"
        if local_sha=$(git rev-parse --verify --quiet "refs/pull/$number/head") && [ "$local_sha" = "$head_sha" ]; then
            if ! git update-ref "refs/risk-scan/pr-$number" "$local_sha"; then
                fail "no se pudo preparar el ref local de inspección de la PR #$number."
                return 1
            fi
        elif ! git fetch --no-tags origin "refs/pull/$number/head:refs/risk-scan/pr-$number" >"$fetch_log" 2>&1; then
            cat "$fetch_log" >&2
            fail "no se pudo obtener el head de la PR #$number; no se escribe ninguna PR."
            return 1
        fi
        if ! ref_sha=$(git rev-parse --verify --quiet "refs/risk-scan/pr-$number^{commit}"); then
            fail "el ref de inspección de la PR #$number no resuelve a un commit."
            return 1
        fi
        if [ "$ref_sha" != "$head_sha" ]; then
            fail "el head obtenido de la PR #$number no coincide con el SHA listado."
            return 1
        fi
        printf '%s\t%s\n' "$number" "$head_sha" >>"$inventory_file"
    done <"$source_file"
}

run_evaluator() {
    local inventory_file="$1" findings_file="$2" evaluator
    evaluator="$(cd "$(dirname "$0")" && pwd)/evaluar-riesgos-integracion.sh"
    [ -x "$evaluator" ] || { fail "el evaluador no es ejecutable: $evaluator"; return 1; }
    if ! bash "$evaluator" --main-sha "$MAIN_SHA" --inventario "$inventory_file" >"$findings_file" 2>"$tmp_dir/evaluator.err"; then
        cat "$tmp_dir/evaluator.err" >&2
        fail 'la evaluación de riesgos no pudo completarse; se conserva el estado existente.'
        return 1
    fi
    if [ -s "$findings_file" ] && ! awk -F '\t' 'NF != 3 { exit 1 }' "$findings_file"; then
        fail 'el evaluador produjo una salida TSV inválida.'
        return 1
    fi
}

collect_snapshot() {
    local attempt_dir="$1" raw_prs prs_file
    raw_prs="$attempt_dir/prs.raw"
    prs_file="$attempt_dir/prs.json"
    mkdir -p "$attempt_dir"
    list_open_prs "$raw_prs" "$prs_file" || return 1
    collect_snapshot_from_file "$attempt_dir" "$prs_file"
}

collect_snapshot_from_file() {
    local attempt_dir="$1" prs_file="$2" inventory_file findings_file count
    inventory_file="$attempt_dir/inventario.tsv"
    findings_file="$attempt_dir/hallazgos.tsv"
    check_origin_main || return 1
    fetch_heads_and_inventory "$prs_file" "$inventory_file" || return 1
    if ! count=$(jq 'length' "$prs_file"); then
        fail 'no se pudo contar el inventario de PRs.'
        return 1
    fi
    if [ "$count" -gt 0 ]; then
        run_evaluator "$inventory_file" "$findings_file" || return 1
    else
        : >"$findings_file"
    fi
    SNAPSHOT_PRS="$prs_file"
    SNAPSHOT_INVENTORY="$inventory_file"
    SNAPSHOT_FINDINGS="$findings_file"
    SNAPSHOT_COUNT="$count"
}

register_drift() {
    REVALIDATION_PRS="$1"
    SNAPSHOT_DRIFT=1
    collect_salientes_confirmadas "$2"
}

normalize_prs() {
    local source_file="$1" target_file="$2"
    if ! jq -S 'map({number: (.number | floor), state, base: .base.ref, head: .head.sha}) | sort_by(.number)' "$source_file" >"$target_file"; then
        fail 'no se pudo normalizar el inventario de PRs.'
        return 1
    fi
}

accumulate_salientes_confirmadas_from_inventory() {
    local previous_file="$1" current_file="$2" new_file
    new_file="$SALIENTES_CONFIRMADAS_FILE.new"
    if ! jq -nr --slurpfile previous "$previous_file" --slurpfile current "$current_file" '
        ($previous[0] | map(.number | floor)) as $previous_numbers
        | ($current[0] | map(.number | floor)) as $current_numbers
        | (($previous_numbers - $current_numbers) | .[]? | tostring)
    ' >"$new_file"; then
        fail 'no se pudo identificar las PRs salientes del inventario.'
        return 1
    fi
    merge_salientes_confirmadas "$new_file"
}

merge_salientes_confirmadas() {
    local new_numbers_file="$1" merged_file="$SALIENTES_CONFIRMADAS_FILE.merged"
    if ! sort -n -u "$SALIENTES_CONFIRMADAS_FILE" "$new_numbers_file" >"$merged_file"; then
        fail 'no se pudo acumular el conjunto de salientes confirmadas.'
        return 1
    fi
    if ! mv "$merged_file" "$SALIENTES_CONFIRMADAS_FILE"; then
        fail 'no se pudo conservar el conjunto acumulado de salientes confirmadas.'
        return 1
    fi
}

add_saliente_confirmada() {
    local number="$1" new_file="$SALIENTES_CONFIRMADAS_FILE.new"
    if ! printf '%s\n' "$number" >"$new_file"; then
        fail "no se pudo acumular la PR #$number como saliente confirmada."
        return 1
    fi
    merge_salientes_confirmadas "$new_file"
}

read_comments() {
    local number="$1" output_file="$2" raw_file endpoint
    endpoint="repos/$REPOSITORY/issues/$number/comments?per_page=100"
    raw_file="$output_file.raw"
    if ! gh api --paginate "$endpoint" >"$raw_file" 2>"$tmp_dir/comments-$number.err"; then
        cat "$tmp_dir/comments-$number.err" >&2
        fail "no se pudieron leer todos los comentarios de la PR #$number."
        return 1
    fi
    if ! jq -s 'if length == 0 then [] else add end' "$raw_file" >"$output_file"; then
        fail "los comentarios de la PR #$number no son JSON válido."
        return 1
    fi
    if ! jq -e 'type == "array" and all(.[]; type == "object" and (.body | type) == "string")' "$output_file" >/dev/null; then
        fail "los comentarios de la PR #$number tienen una forma inesperada."
        return 1
    fi
}

read_labels() {
    local number="$1" output_file="$2" endpoint
    endpoint="repos/$REPOSITORY/issues/$number/labels?per_page=100"
    if ! gh api --paginate "$endpoint" >"$output_file.raw" 2>"$tmp_dir/labels-$number.err"; then
        cat "$tmp_dir/labels-$number.err" >&2
        fail "no se pudieron leer las etiquetas de la PR #$number."
        return 1
    fi
    if ! jq -s 'if length == 0 then [] else add end' "$output_file.raw" >"$output_file"; then
        fail "las etiquetas de la PR #$number no son JSON válido."
        return 1
    fi
    if ! jq -e 'type == "array" and all(.[]; type == "object" and (.name | type) == "string")' "$output_file" >/dev/null; then
        fail "las etiquetas de la PR #$number tienen una forma inesperada."
        return 1
    fi
}

collect_state() {
    local prs_file="$1" state_dir="$2" number expected_sha detail_file detail_number detail_state detail_base detail_sha remote_sha
    local normalized_expected normalized_actual previous_salientes_file="$SALIENTES_CONFIRMADAS_FILE"
    SNAPSHOT_DRIFT=0
    mkdir -p "$state_dir"
    SNAPSHOT_STATE_DIR="$state_dir"
    if [ -n "$previous_salientes_file" ] && [ -f "$previous_salientes_file" ]; then
        if ! cp "$previous_salientes_file" "$state_dir/salientes-confirmadas.tsv"; then
            fail 'no se pudo conservar el conjunto de salientes confirmadas.'
            return 1
        fi
    else
        : >"$state_dir/salientes-confirmadas.tsv"
    fi
    SALIENTES_CONFIRMADAS_FILE="$state_dir/salientes-confirmadas.tsv"
    if ! remote_sha=$(origin_main_sha); then
        fail 'no se pudo confirmar main antes de mutar.'
        return 1
    fi
    if [ "$remote_sha" != "$MAIN_SHA" ]; then
        register_drift "$prs_file" "$state_dir" || return 1
        return 0
    fi

    if ! list_open_prs "$state_dir/revalidation.raw" "$state_dir/revalidation.json"; then
        fail 'no se pudo reinventariar las PRs antes de mutar.'
        return 1
    fi
    normalized_expected="$state_dir/expected.tsv"
    normalized_actual="$state_dir/actual.tsv"
    normalize_prs "$prs_file" "$normalized_expected" || return 1
    normalize_prs "$state_dir/revalidation.json" "$normalized_actual" || return 1
    if ! cmp -s "$normalized_expected" "$normalized_actual"; then
        if ! accumulate_salientes_confirmadas_from_inventory "$prs_file" "$state_dir/revalidation.json"; then
            return 1
        fi
        register_drift "$state_dir/revalidation.json" "$state_dir" || return 1
        return 0
    fi

    while IFS=$'\t' read -r number expected_sha; do
        [ -n "$number" ] || continue
        detail_file="$state_dir/detail-$number.json"
        if ! gh api "repos/$REPOSITORY/pulls/$number" >"$detail_file" 2>"$tmp_dir/detail-$number.err"; then
            cat "$tmp_dir/detail-$number.err" >&2
            printf '::error::marcar-prs-en-riesgo: no se pudo releer el detalle de la PR #%s; evidencia incompleta, no se muta ninguna PR.\n' "$number" >&2
            return 1
        fi
        if ! jq -e 'type == "object" and (.number | type) == "number" and (.state | type) == "string" and (.base | type) == "object" and (.head | type) == "object" and (.base.ref | type) == "string" and (.head.sha | type) == "string"' "$detail_file" >/dev/null; then
            fail "la relectura de la PR #$number tiene una forma inesperada."
            return 1
        fi
        detail_number=$(jq -r '.number | floor | tostring' "$detail_file")
        detail_state=$(jq -r '.state' "$detail_file")
        detail_base=$(jq -r '.base.ref' "$detail_file")
        detail_sha=$(jq -r '.head.sha' "$detail_file")
        if [ "$detail_number" != "$number" ] || [ "$detail_state" != open ] || [ "$detail_base" != main ] || [ "$detail_sha" != "$expected_sha" ]; then
            # Un head distinto sigue siendo deriva inestable; solo acumula una salida con el detalle del head que se evaluó.
            if [ "$detail_number" = "$number" ] && [ "$detail_sha" = "$expected_sha" ] && { [ "$detail_state" != open ] || [ "$detail_base" != main ]; }; then
                if ! add_saliente_confirmada "$number"; then
                    return 1
                fi
            fi
            register_drift "$state_dir/revalidation.json" "$state_dir" || return 1
            return 0
        fi
    done < "$SNAPSHOT_INVENTORY"
    while IFS=$'\t' read -r number _expected_sha; do
        [ -n "$number" ] || continue
        read_comments "$number" "$state_dir/comments-$number.json" || return 1
        read_labels "$number" "$state_dir/labels-$number.json" || return 1
        awk -F '\t' -v number="$number" '$1 == number { print }' "$SNAPSHOT_FINDINGS" >"$state_dir/findings-$number.tsv"
    done < "$SNAPSHOT_INVENTORY"
    collect_salientes_confirmadas "$state_dir" || return 1
}

count_own_comments() {
    jq -r --arg marker "$MARKER" "$OWN_COMMENTS | length" "$1"
}

own_comment_id() {
    jq -r --arg marker "$MARKER" "$OWN_COMMENTS | .[0].id | tostring" "$1"
}

own_comment_body() {
    jq -r --arg marker "$MARKER" "$OWN_COMMENTS | .[0].body // empty" "$1"
}

has_label() {
    local labels_file="$1"
    jq -e --arg label "$LABEL" 'any(.[]; .name == $label)' "$labels_file" >/dev/null
}

preflight_label() {
    local output_file="$tmp_dir/label-preflight.json"
    if gh api "repos/$REPOSITORY/labels/$LABEL_SEGMENT" >"$output_file" 2>"$tmp_dir/label-preflight.err"; then
        if ! jq -e 'type == "object" and (.name | type) == "string"' "$output_file" >/dev/null; then
            fail "la respuesta de la etiqueta $LABEL tiene una forma inesperada."
            return 1
        fi
        return 0
    fi
    if grep -Eiq 'HTTP[[:space:]]+404|Not Found' "$tmp_dir/label-preflight.err"; then
        fail "la etiqueta $LABEL no existe; crea la etiqueta $LABEL antes de ejecutar el workflow."
    else
        cat "$tmp_dir/label-preflight.err" >&2
        fail "no se pudo verificar la etiqueta $LABEL antes de mutar."
    fi
    return 1
}

build_comment() {
    local findings_file="$1" code detail has_lock=0 has_flyway=0
    printf '%s\n' "$MARKER"
    printf 'Riesgo de integración detectado.\n\n'
    while IFS=$'\t' read -r _number code detail; do
        [ -n "$code" ] || continue
        printf -- "- \`%s\`: \`%s\`\n" "$code" "$detail"
        case "$code" in
            LOCKFILE_DIVERGENTE) has_lock=1 ;;
            FLYWAY_*) has_flyway=1 ;;
        esac
    done < "$findings_file"
    printf '\n'
    if [ "$has_lock" -eq 1 ] && [ "$has_flyway" -eq 1 ]; then
        printf 'Renumera las migraciones, actualiza la rama y regenera los lockfiles.'
    elif [ "$has_lock" -eq 1 ]; then
        printf 'Actualiza la rama y regenera el lockfile.'
    else
        printf 'Renumera la migración antes de actualizar la rama.'
    fi
}

mutation_count=0
mutation_window_start=0
last_mutation_error=''
SALIENTES_CONFIRMADAS_FILE=''
mutation_retry_allowed=1
OWN_COMMENTS="[.[] | select((.body | contains(\$marker)) and (.user | type) == \"object\" and (.user.type // \"\") == \"Bot\" and (.id != null))]"

collect_salientes_confirmadas() {
    local state_dir="$1" number detail_file
    [ -n "$SALIENTES_CONFIRMADAS_FILE" ] || return 0
    [ -f "$SALIENTES_CONFIRMADAS_FILE" ] || return 0
    while IFS= read -r number; do
        [ -n "$number" ] || continue
        detail_file="$state_dir/saliente-detail-$number.json"
        if ! gh api "repos/$REPOSITORY/pulls/$number" >"$detail_file" 2>"$tmp_dir/saliente-detail-$number.err"; then
            cat "$tmp_dir/saliente-detail-$number.err" >&2
            fail "no se pudo confirmar el estado de la PR #$number saliente."
            return 1
        fi
        if ! jq -e --argjson number "$number" '
            type == "object"
            and (.number | type) == "number"
            and (.number | floor) == $number
            and (.state | type) == "string"
            and (.base | type) == "object"
            and (.base.ref | type) == "string"
            and (.head | type) == "object"
            and (.head.sha | type) == "string"
            and (.state != "open" or .base.ref != "main")
        ' "$detail_file" >/dev/null; then
            fail "la PR #$number sigue elegible o tiene una relectura inválida; no se limpian sus marcas."
            return 1
        fi
        read_comments "$number" "$state_dir/saliente-comments-$number.json" || return 1
        read_labels "$number" "$state_dir/saliente-labels-$number.json" || return 1
    done <"$SALIENTES_CONFIRMADAS_FILE"
}

wait_seconds() {
    local effective="${TEST_WAIT:-$1}"
    if [ "$effective" -gt 0 ]; then
        sleep "$effective"
    fi
}

before_mutation() {
    local now elapsed wait
    now=$(date +%s)
    if [ "$mutation_window_start" -eq 0 ]; then
        mutation_window_start="$now"
    fi
    elapsed=$((now - mutation_window_start))
    if [ "$elapsed" -ge 60 ]; then
        mutation_count=0
        mutation_window_start="$now"
    elif [ "$mutation_count" -ge "$MAX_MUTATIONS" ]; then
        wait=$((60 - elapsed))
        wait_seconds "$wait"
        mutation_count=0
        mutation_window_start=$(date +%s)
    fi
    mutation_count=$((mutation_count + 1))
}

gh_mutation_once() {
    local rc
    before_mutation
    last_mutation_error="$tmp_dir/last-mutation.err"
    if gh "$@" --include >"$tmp_dir/last-mutation.out" 2>"$last_mutation_error"; then
        return 0
    else
        rc=$?
        cat "$last_mutation_error" >&2
        return "$rc"
    fi
}

retryable_mutation_error() {
    grep -Eiq 'HTTP[^[:space:]]*[[:space:]]+(429|403)|^Retry-After:' "$last_mutation_error" "$tmp_dir/last-mutation.out" 2>/dev/null
}

retry_after_seconds() {
    local value
    value=$(sed -n 's/^[Rr]etry-[Aa]fter:[[:space:]]*//p' "$tmp_dir/last-mutation.out" "$last_mutation_error" | head -n 1 || true)
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        printf '%s' "$value"
    else
        printf '60'
    fi
}

retry_mutation() {
    local attempt=1
    while [ "$attempt" -le 3 ]; do
        mutation_retry_allowed=1
        if "$@"; then
            return 0
        fi
        if [ "$mutation_retry_allowed" -eq 0 ] || ! retryable_mutation_error || [ "$attempt" -eq 3 ]; then
            return 1
        fi
        wait_seconds "$(retry_after_seconds)"
        attempt=$((attempt + 1))
    done
    return 1
}

write_comment_json() {
    local number="$1" body="$2" json_file="$tmp_dir/comment-$1.json"
    if ! printf '%s' "$body" | jq -Rs '{body: .}' >"$json_file"; then
        fail "no se pudo serializar el comentario de la PR #$number."
        return 1
    fi
    printf '%s\n' "$json_file"
}

post_comment() {
    local number="$1" body="$2" comments_file="$3" json_file
    if ! json_file=$(write_comment_json "$number" "$body"); then
        return 1
    fi
    retry_mutation post_comment_attempt "$number" "$body" "$comments_file" "$json_file"
}

post_comment_attempt() {
    local number="$1" body="$2" comments_file="$3" json_file="$4" count own_id own_body
    if gh_mutation_once api --method POST "repos/$REPOSITORY/issues/$number/comments" --input "$json_file"; then
        return 0
    fi
    if ! read_comments "$number" "$comments_file"; then
        mutation_retry_allowed=0
        return 1
    fi
    if ! count=$(count_own_comments "$comments_file"); then
        fail "no se pudo contar el comentario propio de la PR #$number."
        mutation_retry_allowed=0
        return 1
    fi
    if [ "$count" -gt 1 ]; then
        warning "la PR #$number tiene $count comentarios propios después de un POST ambiguo; no se reintenta la creación."
        mutation_retry_allowed=0
        return 1
    fi
    if [ "$count" -eq 1 ]; then
        if ! own_body=$(own_comment_body "$comments_file"); then
            fail "no se pudo leer el comentario propio de la PR #$number."
            mutation_retry_allowed=0
            return 1
        fi
        if [ "$own_body" = "$body" ]; then
            return 0
        fi
        if ! own_id=$(own_comment_id "$comments_file"); then
            fail "no se pudo identificar el comentario propio de la PR #$number."
            mutation_retry_allowed=0
            return 1
        fi
        if ! patch_comment "$number" "$own_id" "$body"; then
            mutation_retry_allowed=0
            return 1
        fi
        return 0
    fi
    return 1
}

patch_comment() {
    local number="$1" comment_id="$2" body="$3" json_file
    if ! json_file=$(write_comment_json "$number" "$body"); then
        return 1
    fi
    retry_mutation gh_mutation_once api --method PATCH "repos/$REPOSITORY/issues/comments/$comment_id" --input "$json_file"
}

add_label() {
    local number="$1" json_file="$tmp_dir/label-$1.json"
    if ! printf '%s' "$LABEL" | jq -Rs '{labels: [.]}' >"$json_file"; then
        fail "no se pudo serializar la etiqueta de la PR #$number."
        return 1
    fi
    retry_mutation gh_mutation_once api --method POST "repos/$REPOSITORY/issues/$number/labels" --input "$json_file"
}

remove_label() {
    local number="$1"
    retry_mutation gh_mutation_once api --method DELETE "repos/$REPOSITORY/issues/$number/labels/$LABEL_SEGMENT"
}

comment_ausente() {
    local number="$1" comment_id="$2" recheck_file
    recheck_file="$tmp_dir/comments-recheck-$number.json"
    read_comments "$number" "$recheck_file" || return 1
    jq -e --arg id "$comment_id" 'all(.[]; (.id | tostring) != $id)' "$recheck_file" >/dev/null
}

delete_comment() {
    local number="$1" comment_id="$2"
    retry_mutation delete_comment_attempt "$number" "$comment_id"
}

delete_comment_attempt() {
    local number="$1" comment_id="$2"
    if gh_mutation_once api --method DELETE "repos/$REPOSITORY/issues/comments/$comment_id"; then
        return 0
    fi
    if ! retryable_mutation_error; then
        if grep -Eiq 'HTTP[[:space:]]+404' "$last_mutation_error" && comment_ausente "$number" "$comment_id"; then
            return 0
        fi
        mutation_retry_allowed=0
    fi
    return 1
}

reconcile_pr() {
    local number="$1" findings_file="$SNAPSHOT_STATE_DIR/findings-$1.tsv" comments_file="$SNAPSHOT_STATE_DIR/comments-$1.json" labels_file="$SNAPSHOT_STATE_DIR/labels-$1.json" own_count own_id own_body desired risk=0
    [ -s "$findings_file" ] && risk=1
    if ! own_count=$(count_own_comments "$comments_file"); then
        fail "no se pudo contar el comentario propio de la PR #$number."
        return 1
    fi
    if [ "$own_count" -gt 1 ]; then
        warning "la PR #$number tiene $own_count comentarios propios con el marcador; no se hace borrado masivo."
    fi
    if [ "$risk" -eq 1 ]; then
        desired=$(build_comment "$findings_file")
        if [ "$own_count" -eq 0 ]; then
            post_comment "$number" "$desired" "$comments_file" || return 1
        elif [ "$own_count" -eq 1 ]; then
            if ! own_id=$(own_comment_id "$comments_file"); then
                fail "no se pudo identificar el comentario propio de la PR #$number."
                return 1
            fi
            if ! own_body=$(own_comment_body "$comments_file"); then
                fail "no se pudo leer el comentario propio de la PR #$number."
                return 1
            fi
            if [ "$own_body" != "$desired" ]; then
                patch_comment "$number" "$own_id" "$desired" || return 1
            fi
        fi
        if ! has_label "$labels_file"; then
            add_label "$number" || return 1
        fi
    else
        if has_label "$labels_file"; then
            remove_label "$number" || return 1
        fi
        if [ "$own_count" -eq 1 ]; then
            if ! own_id=$(own_comment_id "$comments_file"); then
                fail "no se pudo identificar el comentario propio de la PR #$number."
                return 1
            fi
            delete_comment "$number" "$own_id" || return 1
        fi
    fi
}

reconcile_saliente_pr() {
    local number="$1" comments_file="$SNAPSHOT_STATE_DIR/saliente-comments-$1.json" labels_file="$SNAPSHOT_STATE_DIR/saliente-labels-$1.json" own_count own_id
    if ! own_count=$(count_own_comments "$comments_file"); then
        fail "no se pudo contar el comentario propio de la PR #$number saliente."
        return 1
    fi
    if [ "$own_count" -gt 1 ]; then
        warning "la PR #$number saliente tiene $own_count comentarios propios; no se hace borrado masivo."
        return 0
    fi
    if has_label "$labels_file"; then
        remove_label "$number" || return 1
    fi
    if [ "$own_count" -eq 1 ]; then
        if ! own_id=$(own_comment_id "$comments_file"); then
            fail "no se pudo identificar el comentario propio de la PR #$number saliente."
            return 1
        fi
        delete_comment "$number" "$own_id" || return 1
    fi
}

reconcile_prs() {
    local include_current="$1" number _sha reconciled=0 failures=0
    if [ "$include_current" -eq 1 ]; then
        while IFS=$'\t' read -r number _sha; do
            [ -n "$number" ] || continue
            if reconcile_pr "$number"; then
                reconciled=$((reconciled + 1))
            else
                failures=$((failures + 1))
                warning "no se pudo reconciliar por completo la PR #$number; se conserva cualquier estado parcial."
            fi
        done < "$SNAPSHOT_INVENTORY"
    fi
    if [ -n "$SALIENTES_CONFIRMADAS_FILE" ] && [ -f "$SALIENTES_CONFIRMADAS_FILE" ]; then
        while IFS= read -r number; do
            [ -n "$number" ] || continue
            if reconcile_saliente_pr "$number"; then
                reconciled=$((reconciled + 1))
            else
                failures=$((failures + 1))
                warning "no se pudo limpiar por completo la PR #$number saliente."
            fi
        done <"$SALIENTES_CONFIRMADAS_FILE"
    fi
    if [ "$failures" -gt 0 ] && [ "$reconciled" -eq 0 ]; then
        return 2
    fi
    return 0
}

main() {
    local attempt=0 attempt_dir state_dir pending_prs=''
    require_environment || return 2
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/marcar-prs-en-riesgo.XXXXXX") || {
        fail 'no se pudo crear el directorio temporal.'
        return 2
    }
    while [ "$attempt" -lt 2 ]; do
        attempt_dir="$tmp_dir/attempt-$attempt"
        if [ -n "$pending_prs" ]; then
            mkdir -p "$attempt_dir"
            if ! cp "$pending_prs" "$attempt_dir/prs.json"; then
                fail 'no se pudo materializar el inventario de la recomputación.'
                return 2
            fi
            if ! collect_snapshot_from_file "$attempt_dir" "$attempt_dir/prs.json"; then
                return 2
            fi
        elif ! collect_snapshot "$attempt_dir"; then
            return 2
        fi
        if ! preflight_label; then
            return 2
        fi
        if [ "$SNAPSHOT_COUNT" -eq 0 ] && { [ -z "$SALIENTES_CONFIRMADAS_FILE" ] || [ ! -s "$SALIENTES_CONFIRMADAS_FILE" ]; }; then
            printf 'marcar-prs-en-riesgo: cero PRs abiertas elegibles; no se escribe.\n'
            return 0
        fi
        state_dir="$attempt_dir/state"
        if ! collect_state "$SNAPSHOT_PRS" "$state_dir"; then
            return 2
        fi
        if [ "$SNAPSHOT_DRIFT" -eq 1 ]; then
            if [ "$attempt" -eq 0 ]; then
                pending_prs="$REVALIDATION_PRS"
                attempt=1
                continue
            fi
            warning 'el snapshot derivó por segunda vez; se conservan las marcas de las PRs vigentes y no se escribe sobre ellas.'
            reconcile_prs 0
            return $?
        fi
        reconcile_prs 1
        return $?
    done
    return 0
}

main "$@"
