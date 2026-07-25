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

## Uso
```bash
MARGIN_N=20000 venv/bin/python tools/prune-vocab.py     # margen de piezas latinas por frecuencia
```
Escribe a `~/.local/share/antares-memory/models/mini-es-en/`. Se activa con
`ANTARES_MODEL=<ruta>` (drop-in de systemd). Rollback: borrar el drop-in y reiniciar.
