# =============================================================================
# FILE: logger.py
# PURPOSE: Centralised logging configuration used by all ETL scripts.
#          Writes structured logs to both console and a rotating file.
# =============================================================================

import logging
import logging.handlers
import pathlib
import sys
from datetime import datetime

def get_logger(name: str, log_dir: pathlib.Path = None) -> logging.Logger:
    """
    Create and return a configured logger.

    Args:
        name:    Logger name (use __name__ in calling module).
        log_dir: Directory for log files. Defaults to project/logs/.

    Returns:
        Configured logging.Logger instance.
    """
    if log_dir is None:
        log_dir = pathlib.Path(__file__).parent.parent / "logs"

    log_dir.mkdir(parents=True, exist_ok=True)

    logger = logging.getLogger(name)
    logger.setLevel(logging.DEBUG)

    # Avoid adding duplicate handlers on re-import
    if logger.handlers:
        return logger

    formatter = logging.Formatter(
        fmt="%(asctime)s | %(levelname)-8s | %(name)s | %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    # ── Console handler (INFO and above) ─────────────────────────────────────
    console_handler = logging.StreamHandler(sys.stdout)
    console_handler.setLevel(logging.INFO)
    console_handler.setFormatter(formatter)

    # ── File handler (DEBUG and above, rotating — 5 MB × 5 files) ────────────
    log_filename = log_dir / f"etl_{datetime.utcnow().strftime('%Y%m%d')}.log"
    file_handler = logging.handlers.RotatingFileHandler(
        filename=log_filename,
        maxBytes=5 * 1024 * 1024,   # 5 MB
        backupCount=5,
        encoding="utf-8",
    )
    file_handler.setLevel(logging.DEBUG)
    file_handler.setFormatter(formatter)

    logger.addHandler(console_handler)
    logger.addHandler(file_handler)

    return logger
