# Automation SSH identity

Privileged fleet planning uses a node-local identity file separate from the
portable fleet configuration. Set `ROUNDHOUSE_IDENTITY`, or create
`identity.json` beside the default `config.json`. Keep it outside repositories,
plugin caches, and synced folders with an owner-only private key.

The version 1 identity contains the fleet domain, node ID, absolute private-key,
certificate, and dedicated known-hosts paths, expected node-key and fleet-CA
SHA256 fingerprints, CA generation, certificate serial and validity, and local
enrollment receipts. `worker-config` never projects this file or its paths.

Portable `automation_transport` routes name an explicit host, port, request
user, pinned host-key fingerprint, and management networks. They do not accept
SSH aliases, options, proxy or local commands, control sockets, or credential
bytes. The automation client must bypass ordinary SSH configuration and agents.

Enrollment and protected policy activation remain human operations. Editing a
portable `policy_proposal` only prepares a candidate; it never changes the
root- or Administrator-owned active generation.

Use `roundhouse prepare-privilege-identity` to wrap the fixed
`prepare-ssh-identity prepare` helper. It emits only the public certificate
request and preparation record; it never performs remote access, elevation, or
CA use. Both Codex and Claude must ignore `SSH_AUTH_SOCK` for unattended work
and must never display, copy, request, or relay the private node key or an
elevation password.

Certification is an isolated owner ceremony. Obtain the authenticated release
digest for `scripts/certify-ssh-node` through a separate trusted path, compare
it with the signing account's protected `helper.sha256`, and independently
hash the executing helper inside that account before every signing operation.
Inspect the public manifest before signing and the certificate afterward. The
CA private key is offline, absent from fleet-node and service-account
configuration, and never returned with the public certificate or receipt.

Certificates have finite validity. Renewal prepares a new local certificate,
canaries it against representative POSIX and Windows endpoints, and switches
the node overlay only after those checks pass. Keep the old identity during
the canary. Revoke a compromised node with an owner-generated KRL and confirm
the expected KRL generation on every target; rotate the CA through a proven
dual-trust window. See `windows-sftp.md` for the complete enrollment,
upgrade, recovery, and revocation sequence.
