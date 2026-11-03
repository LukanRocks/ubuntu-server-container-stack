# Storage layout

Everything the media stack reads or writes lives on one SMB share from the TrueNAS box,
mounted **once** at `mounts/library` (`$DOCKER_LIBRARY_MOUNT_DIR`). Containers bind
subdirectories of that single mount.

## Why one mount and not one per folder

Radarr and Sonarr import a finished download by **hardlinking** it into the media library:
the file appears in both places, costs disk space once, and qBittorrent keeps seeding the
same bytes. If the link can't be made they silently fall back to copying — two full copies
of every file on the NAS.

Hardlinks cannot cross a mount point. This share used to be mounted as six separate CIFS
mounts (one per folder), which the kernel treats as six devices:

```
stat -c %d  ->  130 mounts/torrents   56 mounts/movies   52 mounts/shows
ln mounts/torrents/.src mounts/movies/.lnk
  -> ln: failed to create hard link: Invalid cross-device link
```

Within a single mount, the same operation works — SMB3 against TrueNAS supports hardlinks
fine (`links=2`, one inode). So the mount layout was the only obstacle, and
`Invalid cross-device link` is the symptom to recognise if anyone splits it up again.

One mount buys three things:

1. **Hardlinks** on import, instead of copies.
2. **Atomic completion** — qBittorrent moving a finished torrent out of `incomplete/` is a
   rename on the same device, not a copy-then-delete.
3. **Identical path strings everywhere.** qBittorrent reports a download at
   `/data/Torrents/movies/Film.mkv`, and that exact path resolves inside Radarr. This is
   why no *remote path mapping* is needed — do not add one; it's the usual cause of
   "import failed" in arr setups.

## Layout

```
//192.168.1.6/Library  ->  mounts/library          ONE cifs mount, one device
├── Movies/        Jellyfin library  | Radarr root folder  /data/Movies
├── Shows/         Jellyfin library  | Sonarr root folder  /data/Shows
├── Books/         Jellyfin library
├── Courses/       Jellyfin library
├── 3DPrinting/    Bambuddy external root
├── ISOs/          not mounted by any container
├── Manuals/       not mounted by any container
└── Torrents/      qBittorrent, and the only place it can write
    ├── movies/        qBittorrent category "movies"
    ├── shows/         qBittorrent category "shows"
    └── incomplete/    temp path; completing is a rename, same device
```

| Container | Host path | Container path |
| --- | --- | --- |
| qbittorrent | `mounts/library/Torrents` | `/data/Torrents` |
| sonarr / radarr | `mounts/library` | `/data` |
| jellyfin | `mounts/library/{Movies,Shows,Books,Courses}` | `/media/movies`, `/media/shows`, … |
| bambuddy | `mounts/library/3DPrinting` | `/external/3d-printing` |

An arr app needs **both ends of the link** in one bind, so it mounts the whole share at
`/data`. qBittorrent only ever writes inside `Torrents`, so it gets just that subdirectory —
it cannot reach `Movies` or `Shows` at all. The paths still line up because
`mounts/library/Torrents` is mounted at `/data/Torrents`, the same string an arr app sees.

Keep share folder names free of spaces. A space forces the whole volume mapping to be
quoted (`- "$DOCKER_LIBRARY_MOUNT_DIR/Some Folder:/target"`) and had to be escaped octally
(`3D\040Printing`) back when each folder had its own fstab line — which is why
`3D Printing` was renamed to `3DPrinting`. Container-side paths may differ from the share's
(`3DPrinting` is mounted at `/external/3d-printing`, since Bambuddy's
`BAMBUDDY_EXTERNAL_ROOTS` points there).

## Adding a folder

**No `/etc/fstab` change is needed.** Create the directory on the NAS (or just
`mkdir mounts/library/<name>`, since the mount is writable) and bind it into a service:

```yaml
    volumes:
      - $DOCKER_LIBRARY_MOUNT_DIR/<Name>:/some/path:rw
```

An fstab line is only needed to mount a *different* share.

## The mount itself

One line in `/etc/fstab`, automounted by systemd:

```
//192.168.1.6/Library  /home/lukanvanderlinde/services/mounts/library  cifs  credentials=/home/lukanvanderlinde/services/secrets/truenas,uid=1000,gid=1000,file_mode=0644,dir_mode=0755,iocharset=utf8,vers=3.0,rw,_netdev,nofail,x-systemd.automount  0  0
```

`secrets/truenas` is read by `mount.cifs`, not by Docker — which is why it is named without
the `_secrets` suffix the compose env files use, and holds no `KEY=VALUE` lines.

After editing that line:

```bash
sudo systemctl daemon-reload                                        # generates the .mount/.automount units
sudo systemctl start home-lukanvanderlinde-services-mounts-library.automount  # installs the autofs trigger
ls mounts/library                                                   # first access performs the mount
```

The `systemctl start` is easy to miss and not optional: `daemon-reload` only *generates* the
automount unit, so without starting it there is no autofs trigger and the `ls` silently
mounts nothing — it just lists an empty directory. No `systemctl enable` is needed; the
fstab generator writes the `.wants` symlink itself, so the mount returns after a reboot.

## Gotchas, by symptom

**An empty directory inside the container, forever.** Mount before starting a container that
binds it. Docker binds with `rprivate` propagation and `create_host_path: true`, so a
container started while the path is unmounted captures the empty mount point and never sees
the share even after the host mounts it. Confirm with `findmnt -T mounts/library` before
`docker compose up`, and recreate (not restart) the container to fix it.

**`Read-only file system` while `docker inspect` says `rw=true`.** `:ro`/`:rw` on a volume
line cannot grant access a bind doesn't already have. The `ro`/`rw` flag in `/etc/fstab`
decides; change it there, `daemon-reload`, and remount.

**`target is busy` on unmount.** A container still holds the bind. Stop it first — with the
whole stack, `docker compose down`.

**`mount error(2): No such file or directory`.** The subpath doesn't exist in the share.
There's no `smbclient` on this host, so a path can't be verified locally before mounting —
check the TrueNAS UI.

**Root-owned files.** Shouldn't happen: the share mounts with
`uid=1000,forceuid,gid=1000,forcegid`, so everything a container creates belongs to
`lukanvanderlinde` regardless of the user inside the container. No `user:` or `group_add:`
is needed.

## Download and import conventions

- qBittorrent categories map to `Torrents/<category>`, set in
  `data/qbittorrent/qBittorrent/categories.json`. Add a category *and* its folder together.
- Keep the temp path inside the same mount (`/data/Torrents/incomplete`) so completing a
  torrent stays a rename.
- Arr root folders are `/data/Movies` and `/data/Shows` — the same directories Jellyfin
  reads as `/media/movies` and `/media/shows`.
- Never configure a remote path mapping in Sonarr/Radarr. The paths already agree; a mapping
  can only break them.
- Don't move downloads out of `Torrents/` by hand while they're seeding. Let the arr app
  import (hardlink) and leave the original in place.

Related: [network.md](network.md) explains why NAS traffic is unaffected by the VPN tunnel —
CIFS is mounted by the host kernel, so a container behind gluetun sends no SMB packets
through its own network stack.
