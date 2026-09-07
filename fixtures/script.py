#!/usr/bin/env python3
"""Sample Python file for syntax highlighting checks."""
import os, sys

class Greeter:
    def __init__(self, name: str):
        self.name = name

    def greet(self) -> str:
        return f"Hello, {self.name}!"  # f-string

if __name__ == "__main__":
    print(Greeter(sys.argv[1] if len(sys.argv) > 1 else "world").greet())
