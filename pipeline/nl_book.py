#!/usr/bin/env python3
"""NeuralLoop book pipeline: a whole book in, learning loops for the NeuralLoop app out.

    python nl_book.py mybook.pdf
    python nl_book.py mybook.epub --media 1-3 --style kawaii
    python nl_book.py --dry-run          # everything offline, no Google account needed

Re-run the same command to continue after NotebookLM's daily limit.
"""

import sys

if sys.version_info < (3, 10):
    sys.exit("NeuralLoop needs Python 3.10 or newer (you have %d.%d)." % sys.version_info[:2])

from neuralloop_books.cli import main

if __name__ == "__main__":
    sys.exit(main())
