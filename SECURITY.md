# Security policy

lães handles a Microsoft sign-in and runs a local server that AI tools can use, so security reports matter. Thank you for taking the time.

## Reporting a vulnerability

Please **don't open a public issue**. Report it privately through GitHub instead:

1. Go to the [Security tab](https://github.com/jkrenge/laes/security) of this repository.
2. Choose **Report a vulnerability**.
3. Describe the problem, how to reproduce it, and what an attacker could do with it.

You'll get a reply as soon as possible. When it's fixed, you can be credited, if you'd like.

## Supported versions

Only the latest release gets security fixes.

## What's in scope

- **Microsoft sign-in.** The OAuth flow (PKCE, public client) and how tokens are stored (the Keychain).
- **The AI connection (MCP server) on the Mac.**
  - It listens on `127.0.0.1` only and requires a bearer token.
  - Anything that lets another app or another user on the machine reach it without the token, or read the token, is in scope.
  - So is anything that lets a connected tool see items hidden as private.
- **Data on the device.** The offline cache and the queue of unsent changes in Application Support.
- **Notes.** Notes are files in the app's own OneDrive folder; ways to read or write outside that folder are in scope.

Out of scope:
- Problems in Microsoft's services themselves; report those to Microsoft.
- Attacks that need someone already in control of your unlocked Mac or iPhone.
