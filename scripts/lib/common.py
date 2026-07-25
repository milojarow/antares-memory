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

HOME = os.path.expanduser("~")

ANTARES_VENV = os.environ.get(
    "ANTARES_VENV", os.path.join(HOME, ".local", "share", "antares-memory", "venv")
)
ANTARES_STATE = os.environ.get(
    "ANTARES_STATE", os.path.join(HOME, ".local", "state", "antares-memory")
)
ANTARES_MODEL = os.environ.get(
    "ANTARES_MODEL", "paraphrase-multilingual-MiniLM-L12-v2"
)
ANTARES_PROJECTS_DIR = os.path.join(HOME, ".claude", "projects")


def slugify(path):
    """Replicate Claude Code's cwd → slug convention.

    Empirically: '/' → '-'. Edge cases inside ~/.claude/ itself may not
    round-trip perfectly, but those are not normal operator working dirs.
    """
    return path.replace("/", "-")


def memory_dir_for(cwd):
    """Path to the memory dir for a given cwd. Does NOT create."""
    return os.path.join(ANTARES_PROJECTS_DIR, slugify(cwd), "memory")


def home_memory_dir():
    """The 'global' memory dir — Claude Code loads its MEMORY.md when cwd == $HOME.

    Honours ANTARES_GLOBAL_MEMORY_DIR, matching lib/common.sh. Installs that
    predate the slug layout keep their global store elsewhere, and their shell
    side already reads this variable — the Python side did not, so the two halves
    of the same system disagreed about where "global" is.

    That is not cosmetic: install.sh copies these scripts over the live ones, so
    running the documented update path (`git pull && ./install.sh`) on such a
    machine would silently repoint indexing and search at an empty slug dir while
    the real store sat untouched — every memory still on disk, none of them
    findable, and no error anywhere.
    """
    override = os.environ.get("ANTARES_GLOBAL_MEMORY_DIR")
    if override:
        return override
    return memory_dir_for(HOME)


def db_path_for(memory_dir):
    """SQLite index path for a given memory dir."""
    return os.path.join(memory_dir, ".memory-index.db")
