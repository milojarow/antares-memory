# prune-vocab.py — poda el vocabulario del modelo de embeddings

El modelo `paraphrase-multilingual-MiniLM-L12-v2` pesa 447 MB en fp32, y **el 82% de eso
(366 MB, 96M de 117M params) es la tabla de embeddings de sus 250,002 tokens** — un vocabulario
para ~100 idiomas. Un host que sólo indexa español e inglés paga ese peso completo en RAM y swap.

Esta herramienta conserva los pesos EXACTOS y sólo elimina las filas de embeddings de tokens
que el corpus no usa. Resultado medido: **250,002 → 28,154 piezas · 447 MB → 126 MB · RSS del
daemon 1,159 → 584 MB**, con los vectores **bit-idénticos** para el corpus indexado.

## Por qué NO cuantizar
La cuantización int8 es la respuesta refleja y aquí es la equivocada: sólo toca las capas
`Linear`, y la tabla de embeddings no es una `Linear`. Ahorraría 61 MB de 447 (14%).

## Lo que garantiza (y lo que no)
Itera hasta un **punto fijo**: reconstruye el tokenizer podado y compara la tokenización contra
el original sobre el corpus COMPLETO más el log de queries reales, agregando las piezas que
falten, hasta que la divergencia sea cero. Eso hace que los embeddings sean idénticos y **el
índice existente siga válido sin reconstruirse**.

Lo que se pierde por diseño: texto fuera de español/inglés (CJK, cirílico, árabe) ya no embebe
bien — medido, coseno 0.20 contra el original en una frase en japonés.

## Dos trampas que costaron horas (no las repitas)
1. **`tokenizer.json` trae `truncation: {max_length: 128}` horneada.** Cualquier `encode()`
   devuelve máximo 128 tokens sin avisar, así que un escaneo ingenuo del corpus ve ~1% del texto.
   Hay que llamar `tok.no_truncation()` antes de escanear.
2. **Comparar `.tokens` es CIEGO a la sustitución por UNK.** Cuando una pieza falta, el
   tokenizer devuelve `id=<unk>` pero `.tokens` sigue mostrando el carácter original: `'●' == '●'`
   compara igual mientras los ids son 109993 vs 3. La verificación debe comparar **ids mapeados**.

## El corpus se le PREGUNTA al sistema — no lo adivines con un glob
El default era `~/.claude/projects/*/memory/**/*.md`, que asume el store global en el slug de
`$HOME`. En un host con override, ese glob **se salta el store global entero y no falla**:
encuentra los stores de proyecto, imprime un conteo que se ve razonable, y poda contra una
fracción. Medido: 253 de 1,121 archivos — el 77% del texto invisible. Ahora el default sale de
`lib/common.py` (`home_memory_dir()` + `ANTARES_PROJECTS_DIR`); `PRUNE_CORPUS_GLOB` sigue
existiendo y acepta varios globs separados por `:`.

## El log de queries no está en journald si el unit es nuevo
La receta de `journalctl` sólo ve lo que el unit actual haya escrito: en un host donde
`install.sh` acababa de recrear el unit, devolvió **8 líneas**. Las queries no se perdieron —
cada una es un turno de usuario en los transcripts (`~/.claude/projects/*/*.jsonl`), que van
meses atrás. Dos trampas al extraerlas:
- `.message.content` es **string** en un prompt tecleado y **lista** en todo lo demás; tratarlo
  siempre como lista descarta justo los turnos que importan.
- `type == "user"` incluye los **resultados de tools** y los **prompts de los propios lobos**
  (que llevan el digest entero: hasta 578 KB en uno solo). El daemon nunca los ve
  (`CLAUDE_HEADLESS` corta el hook). La distribución los separa sola: p75 = 537 chars,
  p90 = 9,269 — cortar en ~4 KB deja las queries reales y tira los payloads.

Vale la pena: en la corrida de referencia, la iteración 1 encontró **466 trozos divergentes y
525 piezas faltantes**, y prácticamente todas venían de las queries. Sin ese log el punto fijo
se declara sobre el corpus, se ve limpio, y el top-5 se mueve en producción.

## Uso
```bash
MARGIN_N=20000 venv/bin/python tools/prune-vocab.py     # margen de piezas latinas por frecuencia
```
Escribe a `~/.local/share/antares-memory/models/mini-es-en/`. Se activa poniendo la ruta en
**`~/.config/antares-memory/model`** (archivo, no variable: el daemon es hijo de systemd pero
el INDEXADOR no, y si los dos no resuelven el mismo modelo el índice se escribe con uno y se
consulta con otro). Después, `./install.sh` para que el unit lo tome. Rollback: borrar el
archivo y volver a correr `install.sh`.
