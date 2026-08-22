# Problem
Codex (now ChatGPT desktop) version 26 only works with one WSL distro at a time.
It also doesn't work with both a WSL distro and Windows simultaneously.

Also, switching between three different environments (2 WSL distros & Windows) involves
several different steps in various disparate places.

# Solution
These independent scripts unify those steps into one place, so switching between them is seamless.
They were originally placed in the Windows directory %USERPROFILE%/.codex/scripts/

Only the .ps1 script has been verified to function correctly, and it works like a dream.
The others are unverified.

# Usage
For usage, see the documentation at the top of the .ps1 file.
