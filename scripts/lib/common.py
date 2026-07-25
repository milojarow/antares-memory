"""scripts/lib/common.py — shared env resolution for antares-memory Python scripts.

Storage model: Claude Code's native convention.

    ~/.claude/projects/<slugify(cwd)>/memory/   ← auto-loaded MEMORY.md per cwd
    ~/.claude/projects/<slugify($HOME)>/memory/ ← "global" by convention

antares-memory mirrors this so operators never need `@`-imports in CLAUDE.md —
Claude Code already loads MEMORY.md from the cwd's slug dir.

Import from sibling scripts:

    import sys, os
    sys.path.insert(0, os.path.join(os.path.dirname(__file__), "lib"))
    from common import (
        ANTARES_MODEL, ANTARES_STATE, ANTARES_PROJECTS_DIR,
        slugify, memory_dir_for, home_memory_dir, db_path_for,
    )
"""

import os
import re

HOME = os.path.expanduser("~")

CONF_DIR = os.path.join(
    os.environ.get("XDG_CONFIG_HOME") or os.path.join(HOME, ".config"), "antares-memory"
)


def _conf_value(name):
    """First non-comment, non-blank line of CONF_DIR/<name>, or None.

    Machine-local settings live in files, not only in the environment: only the daemon is
    a child of systemd, so a variable added to environment.d after login reaches it and
    none of the hooks or lobos. Twin of antares_conf_value() in common.sh — keep in step.
    """
    try:
        with open(os.path.join(CONF_DIR, name), encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith("#"):
                    return line
    except OSError:
        pass
    return None


ANTARES_VENV = os.environ.get(
    "ANTARES_VENV", os.path.join(HOME, ".local", "share", "antares-memory", "venv")
)
ANTARES_STATE = os.environ.get(
    "ANTARES_STATE", os.path.join(HOME, ".local", "state", "antares-memory")
)
# HuggingFace name or a local directory. A host that pruned the embedding table
# (tools/prune-vocab.py) points this at the pruned copy — and the INDEXER has to resolve
# the same value as the daemon, or the index is written with one model and queried with
# another. Hence a config file rather than only the unit's Environment= line.
ANTARES_MODEL = (
    os.environ.get("ANTARES_MODEL")
    or _conf_value("model")
    or "paraphrase-multilingual-MiniLM-L12-v2"
)
ANTARES_PROJECTS_DIR = os.path.join(HOME, ".claude", "projects")


def slugify(path):
    """Replicate Claude Code's cwd -> slug convention.

    EVERY non-alphanumeric character becomes '-', not only '/'. Derived from
    ground truth rather than assumed: of the 21 slug dirs Claude Code itself had
    created on the host where this was found, this rule explains 19, while the
    slash-only rule explains 16. The three it got wrong were dots and underscores:

        ~/.claude/agents-sdk  -> -home-<user>--claude-agents-sdk
        ~/skills-dev/_inbox   -> -home-<user>-skills-dev--inbox

    Getting those wrong is not cosmetic. It points the whole system at a directory
    Claude Code never fills: the `current` scope finds nothing, and an incremental
    reindex happily creates and indexes that empty phantom while the real store is
    never embedded — rc=0 and a normal banner the entire time.

    Must stay identical to antares_slugify() in common.sh.
    """
    return re.sub(r"[^A-Za-z0-9]", "-", path)


def memory_dir_for(cwd):
    """Path to the memory dir for a given cwd. Does NOT create."""
    return os.path.join(ANTARES_PROJECTS_DIR, slugify(cwd), "memory")


def home_memory_dir():
    """The 'global' memory dir — Claude Code loads its MEMORY.md when cwd == $HOME.

    Resolution, matching lib/common.sh exactly:

        1. $ANTARES_GLOBAL_MEMORY_DIR
        2. the path in $XDG_CONFIG_HOME/antares-memory/global-memory-dir
        3. the $HOME slug

    Installs that predate the slug layout keep their global store elsewhere, and
    their shell side already read the variable — the Python side did not, so the
    two halves of the same system disagreed about where "global" is.

    That is not cosmetic: install.sh copies these scripts over the live ones, so
    running the documented update path (`git pull && ./install.sh`) on such a
    machine would silently repoint indexing and search at an empty slug dir while
    the real store sat untouched — every memory still on disk, none of them
    findable, and no error anywhere.

    The config file is the durable half of the answer. The variable was meant to
    be set in the systemd user environment, on the premise that "the hooks are
    children of systemd" — they are not. Only the daemon is. The hooks and lobos
    descend from the Claude Code process, whose environment was fixed at login,
    so a variable added to environment.d afterwards reaches the daemon and none
    of them: search resolves one store, indexing resolves another, and nothing
    reports a problem. A file is read when it is used, so it cannot be missed
    that way. See the long note in lib/common.sh for the measured case.
    """
    override = os.environ.get("ANTARES_GLOBAL_MEMORY_DIR")
    if override:
        return override
    return _conf_value("global-memory-dir") or memory_dir_for(HOME)


def db_path_for(memory_dir):
    """SQLite index path for a given memory dir."""
    return os.path.join(memory_dir, ".memory-index.db")
