#!/usr/bin/env python3
"""Poda el vocabulario de un modelo sentence-transformers Unigram a los tokens que un corpus
usa + un margen de piezas latinas. Los embeddings conservados son BIT-IDÉNTICOS: el índice
existente sigue válido para texto cuya segmentación sólo use piezas retenidas."""
import json, glob, os, shutil, sys, collections
import numpy as np
from tokenizers import Tokenizer
from safetensors.numpy import load_file, save_file

# Todo configurable por env: esta herramienta se comparte entre hosts.
HF    = os.environ.get('PRUNE_SRC_GLOB', '~/.cache/huggingface/hub/models--sentence-transformers--paraphrase-multilingual-MiniLM-L12-v2/snapshots/*/')
_m    = glob.glob(os.path.expanduser(HF))
if not _m: sys.exit(f"no encontré el modelo fuente en {HF} — bájalo primero o pasa PRUNE_SRC_GLOB")
SRC   = _m[0]
OUT   = os.path.expanduser(os.environ.get('PRUNE_OUT', '~/.local/share/antares-memory/models/mini-es-en'))
CORPUS= os.environ.get('PRUNE_CORPUS_GLOB', '~/.claude/projects/*/memory/**/*.md')
# Log de queries reales: texto NUEVO que el corpus no contiene, y es donde la segmentación se
# rompe. Generarlo con:
#   journalctl --user -u antares-memory-daemon --since "30 days ago" --no-pager \
#     | grep -oP "query='\K[^']+" | sort -u > ~/.local/state/antares-memory/query-log.txt
QLOG  = os.path.expanduser(os.environ.get('PRUNE_QUERY_LOG', '~/.local/state/antares-memory/query-log.txt'))
MARGIN_N = int(os.environ.get('MARGIN_N', 20000))

tj = json.load(open(SRC + 'tokenizer.json'))
vocab = tj['model']['vocab']; V = len(vocab)

def latin_ok(p):
    for ch in p:
        if ch == '▁': continue
        o = ord(ch)
        # 0xA0-0xBF es Latin-1 Supplement: ¡ ¿ · ° « » ± — puntuación ESPAÑOLA que
        # mi filtro original saltaba, dejando '·' fuera del margen.
        if o < 128 or 0xA0 <= o <= 0x24F or 0x2000 <= o <= 0x206F: continue
        return False
    return True

latin   = [i for i,(p,s) in enumerate(vocab) if latin_ok(p)]
singles = [i for i in latin if len(vocab[i][0].replace('▁','')) <= 1]

tok = Tokenizer.from_file(SRC + 'tokenizer.json')
tok.no_truncation(); tok.no_padding()   # tokenizer.json trae truncation max_length=128 horneada:
                                        # sin esto sólo se ven los primeros 128 tokens de cada trozo
used = set()
files = sorted(glob.glob(os.path.expanduser(CORPUS), recursive=True))
if not files: sys.exit(f"corpus vacío en {CORPUS}")
for f in files:
    t = open(f, encoding='utf-8', errors='replace').read()
    for i in range(0, len(t), 50000):
        used.update(tok.encode(t[i:i+50000], add_special_tokens=False).ids)

specials = {0, 1, 2, 3, V-1}                                    # <s> <pad> </s> <unk> <mask>
margin   = sorted(latin, key=lambda i: -vocab[i][1])[:MARGIN_N]
keep     = set(specials) | used | set(singles) | set(margin)

textos = []
for f in files:
    t = open(f, encoding='utf-8', errors='replace').read()
    for i in range(0, len(t), 50000):
        textos.append(t[i:i+50000])
# El punto fijo se verifica también contra las QUERIES REALES del log del daemon. El corpus solo
# no basta: una query es texto NUEVO, y ahí es donde la segmentación se rompía ("agrégale" ->
# "gré"+"gale", piezas que el corpus nunca usó). Medido: 44 de 211 textos no-corpus divergían.
queries = [l.strip() for l in open(QLOG, encoding='utf-8')] if os.path.exists(QLOG) else []
if not queries:
    print(f"  ⚠ sin log de queries en {QLOG} — el punto fijo sólo cubrirá el corpus.\n"
          f"    Las queries son texto NUEVO: sin ellas quedan piezas fuera y el top-5 se mueve.")
textos += [q for q in queries if q]
print(f"  verificación de punto fijo sobre {len(textos)} textos ({len(queries)} son queries reales)")
print(f"corpus: {len(files)} archivos · {len(textos)} trozos · piezas usadas {len(used)} · singles {len(singles)} · margen {MARGIN_N}")

def make_tj(keepset):
    """tokenizer.json con el vocab podado y TODOS los ids remapeados."""
    ks = sorted(keepset); o2n = {o: n for n, o in enumerate(ks)}
    import copy
    t = copy.deepcopy(tj)
    t['model']['vocab'] = [vocab[i] for i in ks]
    t['model']['unk_id'] = o2n[tj['model']['unk_id']]
    for at in t.get('added_tokens', []): at['id'] = o2n[at['id']]
    def remap(node):
        if isinstance(node, dict):
            for k, v in node.items():
                if k == 'ids' and isinstance(v, list): node[k] = [o2n[i] for i in v]
                elif k == 'id' and isinstance(v, int) and v in o2n: node[k] = o2n[v]
                else: remap(v)
        elif isinstance(node, list):
            for v in node: remap(v)
    remap(t.get('post_processor'))
    return t, ks, o2n

# --- PUNTO FIJO: iterar hasta que la segmentación del corpus COMPLETO sea idéntica ---
# Necesario porque el escaneo de piezas no garantiza por sí solo que Unigram elija la misma
# ruta: si falta una sola pieza, esa palabra se re-segmenta y su embedding cambia.
import tempfile
id_of = {p: i for i, (p, _) in enumerate(vocab)}
for it in range(1, 8):
    t_new, ks, o2n = make_tj(keep)
    with tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as fh:
        json.dump(t_new, fh, ensure_ascii=False); tmp = fh.name
    tp = Tokenizer.from_file(tmp); tp.no_truncation(); tp.no_padding()
    os.unlink(tmp)
    faltan, ndif = set(), 0
    for txt in textos:
        a = tok.encode(txt, add_special_tokens=False).ids
        b = tp.encode(txt, add_special_tokens=False).ids
        # Comparar IDS mapeados, NO `.tokens`: cuando una pieza falta, el tokenizer devuelve
        # id=<unk> pero `.tokens` sigue mostrando el CARÁCTER original ('●' == '●'), así que
        # comparar strings es ciego a la sustitución por UNK. Costó 3 queries mal medidas.
        if [o2n.get(i, -1) for i in a] != b:
            ndif += 1
            faltan.update(i for i in a if i not in o2n)
    print(f"  iteración {it}: vocab {len(ks)} · trozos que difieren {ndif} · piezas a agregar {len(faltan)}")
    if ndif == 0:
        print("  ✓ PUNTO FIJO: segmentación idéntica en el corpus completo")
        break
    if not faltan:
        print("  ⚠ difieren pero no faltan piezas — la causa NO es cobertura; abortando")
        sys.exit(1)
    keep |= faltan
else:
    print("  ⚠ no convergió en 7 iteraciones"); sys.exit(1)

keep = sorted(keep); old2new = o2n
print(f"vocab: {V} -> {len(keep)}  ({len(keep)*100/V:.1f}%)")

tensors = load_file(SRC + 'model.safetensors')
EMB = 'embeddings.word_embeddings.weight'
old_emb = tensors[EMB]
tensors[EMB] = np.ascontiguousarray(old_emb[keep])
print(f"  {EMB}: {old_emb.shape} -> {tensors[EMB].shape}  ({tensors[EMB].nbytes/1048576:.1f} MB vs {old_emb.nbytes/1048576:.1f} MB)")
del old_emb

os.makedirs(OUT, exist_ok=True)
save_file(tensors, OUT + '/model.safetensors', metadata={'format': 'pt'})
json.dump(t_new, open(OUT + '/tokenizer.json', 'w'), ensure_ascii=False)
cfg = json.load(open(SRC + 'config.json')); cfg['vocab_size'] = len(keep)
json.dump(cfg, open(OUT + '/config.json', 'w'), indent=2)
for f in ('modules.json', 'sentence_bert_config.json', 'config_sentence_transformers.json',
          'special_tokens_map.json', 'tokenizer_config.json'):
    if os.path.exists(SRC + f): shutil.copy2(SRC + f, OUT + '/' + f)
if os.path.isdir(SRC + '1_Pooling'): shutil.copytree(SRC + '1_Pooling', OUT + '/1_Pooling', dirs_exist_ok=True)
json.dump({'source_model': 'paraphrase-multilingual-MiniLM-L12-v2', 'orig_vocab': V,
           'kept_vocab': len(keep), 'corpus_files': len(files), 'corpus_pieces': len(used),
           'latin_singles': len(singles), 'margin_top_latin': MARGIN_N,
           'fixpoint_verified': 'segmentación idéntica al original en el corpus completo + el log de queries reales'},
          open(OUT + '/PRUNE_INFO.json', 'w'), indent=2)
print(f"\nescrito en {OUT}")
