# Política de Commits — Sin Atribución a Modelos de Lenguaje

## Resumen

Este repositorio implementa una política de **tres capas** para rechazar commits que contengan atribución a modelos de lenguaje (LLM), herramientas de IA generativa, o direcciones de correo de Anthropic.

**Regla global:**
```regex
\b(co-authored-by|claude|anthropic|generated with)\b|noreply@anthropic\.com
```

Case-insensitive. Word boundaries (`\b`) aplican a los palabras clave.

## Aplicación

La regla se aplica a:

- **Subject del commit** — línea de asunto
- **Body del commit** — descripción extendida
- **Trailers** — `Co-Authored-By:`, `Reviewed-By:`, etc.
- **Author identity** — nombre y email del autor (`git var GIT_AUTHOR_IDENT`)
- **Committer identity** — nombre y email del committer

## Rationale

1. **Auditabilidad** — Historio limpio, sin confusión sobre quién escribió realmente el código.
2. **Due diligence** — Claridad sobre la cadena de cambios editoriales.
3. **Claim de autoría** — El código se atribuye al desarrollador humano real, no a herramientas.

## Infraestructura

### Capa 1: `commit-msg` hook (bloqueo local)

**Ubicación:** `.githooks/commit-msg`

- Ejecutable, POSIX sh
- Corre en **cada commit local**
- Lee `$1` (path al `COMMIT_EDITMSG`)
- Valida message body y author identity contra la regex
- Si hay match: imprime `❌ COMMIT RECHAZADO` + líneas ofensoras + exit 1
- Si limpio: exit 0 (commit permitido)

**Activación:** `./scripts/install-git-hooks.sh`

**Bypassable:** `git commit --no-verify` (no recomendado)

### Capa 2: `pre-push` hook (bloqueo local)

**Ubicación:** `.githooks/pre-push`

- Ejecutable, POSIX sh
- Corre **antes de cada push**
- Lee stdin (formato estándar de pre-push)
- Para cada ref, calcula commit range:
  - **Rama nueva** (REMOTE_SHA == 0): `origin/main..LOCAL_SHA` (o fallback `LOCAL_SHA~50..LOCAL_SHA`)
  - **Rama existente**: `REMOTE_SHA..LOCAL_SHA`
- Escanea formato extendido (subject + body + author + committer) contra regex
- Si hay match: imprime `❌ PUSH RECHAZADO` + líneas ofensoras + exit 1

**Activación:** `./scripts/install-git-hooks.sh`

**Bypassable:** `git push --no-verify` (no recomendado)

### Capa 3: `.github/workflows/check-commit-messages.yml` (auditoría post-hoc)

**Ubicación:** `.github/workflows/check-commit-messages.yml`

- GitHub Action, runs-on: `ubuntu-latest`
- Triggers: `push:` + `pull_request:` en `main`
- Calcula RANGE:
  - **Pull request**: `base.sha..head.sha`
  - **Push (rama nueva)**: `origin/main..AFTER` (fallback si BEFORE == 0)
  - **Push (rama existente)**: `BEFORE..AFTER`
- Escanea commits con formato extendido (subject + body + trailers + author + committer) contra regex
- Si hay match: `::error::` + detalles + exit 1
- **No bloquea el push** (es post-hoc), pero queda como paper trail

**Bloqueo efectivo:** Requiere branch protection + "check required" (disponible en repos públicos; privados requieren GitHub Pro).

## Instalación

### Primera vez (obligatorio)

```bash
./scripts/install-git-hooks.sh
```

**Qué hace:**
1. `chmod +x` para `.githooks/commit-msg` y `.githooks/pre-push`
2. `git config --local core.hooksPath .githooks` (idempotente)
3. Self-test: intenta pasar un mensaje con `Co-Authored-By: Claude <noreply@anthropic.com>` al hook; si lo acepta, exit 2 con WARNING
4. Imprime OK

**Clones posteriores:** Los hooks se instalan automáticamente (`.githooks` está versionado en el repo).

## Ejemplos

### ❌ Rechazado

```bash
git commit -m "feat: add validation" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
# Error: commit-msg hook rechaza "Co-Authored-By: Claude"
```

```bash
git commit -m "feat: add validation" -m "thanks to Claude for the help"
# Error: commit-msg hook rechaza "Claude"
```

```bash
git commit -m "feat: add validation" -m "see noreply@anthropic.com"
# Error: commit-msg hook rechaza "noreply@anthropic.com"
```

```bash
git commit -m "feat: add validation" -m "Generated with some-tool v1.0"
# Error: commit-msg hook rechaza "Generated with"
```

### ✅ Aceptado

```bash
git commit -m "feat: add cross-platform validation"
# OK: ningún patrón prohibido
```

```bash
git commit -m "feat: integrate claudette library"
# OK: "claudette" no tiene word boundary de "claude" (boundary check respetado)
```

## Recovery

### Pre-merge (commits no pusheados)

```bash
# Rebase interactivo para editar mensajes
git rebase -i origin/main

# Luego force-push (cuidado: solo si no compartido)
git push --force-with-lease origin your-branch
```

### Post-merge (commits pusheados)

```bash
# Revertir el commit problemático
git revert <commit-hash>
git push origin main
```

## Limitaciones

1. **Repos privados sin GitHub Pro:** Branch protection no está disponible. Capa 3 (workflow) es audit-only. **Capa 2 (pre-push hook) es el bloqueo efectivo.**

2. **`--no-verify`:** Salta capa 1 (commit-msg) y capa 2 (pre-push). No recomendado. Capa 3 (workflow) aún corre post-hoc.

3. **Clones sin instalación:** Si alguien clona el repo y **nunca corre** `./scripts/install-git-hooks.sh`, capas 1 y 2 no aplican. Solo capa 3 (post-hoc, no bloqueante) corre en CI.

## Mantenimiento

### Si cambias la regex

**Cambiarla en TODAS tres capas literalmente:**

1. `.githooks/commit-msg` — variable `REGEX=`
2. `.githooks/pre-push` — variable `REGEX=`
3. `.github/workflows/check-commit-messages.yml` — variable `REGEX=`

(Y aquí en `docs/COMMIT_POLICY.md`.)

### Testing local

```bash
# Test commit-msg hook
echo "Test message

Co-Authored-By: Claude <noreply@anthropic.com>" | .githooks/commit-msg /dev/stdin
# Debería imprimir error y exit 1
```

```bash
# Test pre-push hook (simular stdin)
echo "refs/heads/main abc1234 refs/heads/main def5678" | .githooks/pre-push
# Debería pasar si los commits en abc1234..def5678 están limpios
```

---

**Última actualización:** 2026-04-28  
**Responsable:** Política de autoría editorial
