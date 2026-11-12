# Optional privileged helper — packaging notes

**There is no helper here.** This directory holds only the checklist for whoever builds one later. Nothing in the
Sentinel app depends on it, and the app reports the helper as "deployment unverified".

The protocol the helper must speak is specified in [`docs/HELPER_INTERFACE.md`](../docs/HELPER_INTERFACE.md). The
platform-independent server-side logic (handshake, authorisation, replay protection, validation) already exists as
`HelperServerSession` in `SentinelCore` and can be linked into a daemon; the daemon supplies a socket listener bound
to `127.0.0.1` and a `HelperOperationHandler` that does the privileged work.

## Rules for a helper

* Its own daemon process. Not a tweak, not injected into SpringBoard or any other process.
* Listens on loopback only. Refuses to start without a pairing key of at least 32 bytes.
* Implements only the operations in the interface document. No command execution of any kind.
* Every capture is bounded in time and size. Every filter change is reversible and removed on uninstall.
* Does not start capturing or filtering by itself; it acts only on authenticated requests.

## Packaging layout (to be filled in when the environment is known)

Keep rootful and rootless concerns in the package build, never in `SentinelCore` or the app:

```
Helper/
  daemon/            # future: listener + HelperOperationHandler (links SentinelCore)
  packaging/
    rootful/         # control file, launchd plist, paths under /
    rootless/        # control file, launchd plist, paths under the jailbreak prefix
```

Information required for each package is listed in the table at the end of `docs/HELPER_INTERFACE.md`.

## Not done, on purpose

* No jailbreak is installed or assumed by anything in this repository.
* No package is built or published, and no repository metadata is provided.
* No device is resprung or modified.
