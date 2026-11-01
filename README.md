# Ansible Yandex Cloud Dynamic Inventory Plugin (fork + fixes)

[Русский](README.ru.md) | **English**

An Ansible dynamic inventory plugin for Yandex Cloud: it reads Compute instances
and builds an inventory grouped by availability zone and by VM labels.

> **This is a fork.** The original is
> [mzatolokin/ansible-yandex-cloud-inventory](https://github.com/mzatolokin/ansible-yandex-cloud-inventory)
> (upstream `main`, commit `d2ad1ab`, author Maksim Zatolokin, MIT license).
> Upstream has not been updated for about a year, so fixes are released from
> `morgenvor/ansible-yandex-cloud-inventory` (default branch `local-patches`;
> `main` in the fork points at clean upstream and exists only as a sync point).
> The upstream code is not claimed as new work: this repository is upstream
> code plus fixes. What exactly changed, what the label contract is now and how
> to migrate are described in
> [`docs/upstream-differences.md`](docs/upstream-differences.md)
> (that document is Russian-only for now).

## Features

- Reads Compute instances from Yandex Cloud
- Authentication with an IAM token or a service account key
- Groups by availability zone and by user labels
- `ansible_host` is the public IP (the internal one stays in `private_ipv4`), so
  connections work from outside the cloud as well
- The host name is the VM name as is, dashes included: `ansible web-1 -m ping`
  finds `web-1`, and `web-1` and `web_1` stay two different hosts
- Paginated `ListInstances`, so VMs after the first page are not lost
- An instance can be excluded with the `ansible: false` label (value is
  case-insensitive)
- VM labels are exported as `yc_label_<key>`; only `ansible_user` and
  `ansible_port` become service variables (allowlist), so a label cannot
  override the connection address or execute code on the controller
- Extra groups through the `ansible_group` label — strictly with the `yc_`
  prefix: `ansible_group: docker` creates the group `yc_docker`
- A clear error instead of a traceback when the `yandexcloud` SDK is missing

## Installation

### From source

1. Clone the fork. The default branch `local-patches` is the fork code with the
   fixes; `main` in the fork points at clean upstream and is only used for
   synchronisation:
```bash
git clone https://github.com/morgenvor/ansible-yandex-cloud-inventory.git
cd ansible-yandex-cloud-inventory
```

2. Install the dependencies and the plugin — the single source of dependencies
   is `pyproject.toml`:
```bash
pip install -e .
```

3. Make the plugin visible to Ansible — either through `ansible.cfg` (see
   "With ansible.cfg") or with an environment variable:
```bash
export ANSIBLE_INVENTORY_PLUGINS=./inventory_plugins
```

### With `pip install` (and why that alone is not enough)

```bash
pip install .
```

The package lands in `site-packages` and is importable as a Python module, but
**Ansible will not find the plugin automatically**: ansible-core (verified on
2.19) loads inventory plugins only from plugin directories and collections.
`entry_points` are not read by Ansible at all — there is no such mechanism for
plugins in ansible-core (entry points exist only for `console_scripts` and
roles). So after installing, point Ansible at the plugin directory inside the
environment:

```bash
# path inside venv/site-packages where the installed inventory_plugins/ lives
# (do not run this from the repository root: otherwise Python resolves the local
# inventory_plugins/ directory and prints the path to the sources, not to the
# installed package)
export ANSIBLE_INVENTORY_PLUGINS="$(python -c 'import inventory_plugins, os; print(os.path.dirname(inventory_plugins.__file__))')"
```

The simplest option is to work from the sources and keep
`inventory_plugins = ./inventory_plugins` in `[defaults]` of your `ansible.cfg`
(that is how this repository is set up).

Note that `pip install .` is also the step that installs the `yandexcloud` SDK.
If you copy the plugin directory instead, install the SDK yourself
(`pip install yandexcloud`), otherwise the plugin stops with an explicit error
saying exactly that.

## Configuration

### Authentication

The plugin supports two methods.

#### Service account key (recommended)

```yaml
plugin: yandex_cloud_inventory
folder_id: your-folder-id
service_account_key_file: /path/to/service-account-key.json
```

#### IAM token (handy for one-off checks)

**⚠️ Important:** an IAM token lives for 12 hours and has to be refreshed.

```yaml
plugin: yandex_cloud_inventory
folder_id: your-folder-id
iam_token: your-iam-token
```

The token does not have to be written to a file — it can come from the
`YC_IAM_TOKEN` environment variable:

```yaml
plugin: yandex_cloud_inventory
folder_id: your-folder-id
# iam_token will be taken from the YC_IAM_TOKEN environment variable
```

Refreshing the token:

```bash
yc iam create-token
```

### Options

| Option | Required | Description |
|----------|--------------|----------|
| `plugin` | Yes | Must be `yandex_cloud_inventory` |
| `folder_id` | Yes | Yandex Cloud folder ID |
| `iam_token` | No* | IAM token for authentication |
| `service_account_key_file` | No* | Path to the service account key JSON file |
| `group` | No | Group name every host is added to |

\*Either `iam_token` or `service_account_key_file` is required (the key wins).

### Example configuration

**The file name matters.** The plugin claims only `yc_inventory.yml`
(`.yaml`) or `<prefix>_yc_inventory.yml` — the `_` separator and a non-empty
prefix are mandatory, so `inventory.yml` and `_yc_inventory.yml` are ignored on
purpose: that way foreign inventories are not intercepted. A ready example is
[`examples/yc_inventory.yml`](examples/yc_inventory.yml):

```yaml
plugin: yandex_cloud_inventory
folder_id: <YOUR_FOLDER_ID>
group: ycloud_group
service_account_key_file: <YOUR_SERVICE_ACCOUNT_KEY_FILE>
```

Or with the token from the environment:

```bash
export YC_IAM_TOKEN="your-iam-token"
```

```yaml
plugin: yandex_cloud_inventory
folder_id: <YOUR_FOLDER_ID>
group: ycloud_group
```

## Usage

### Checking the inventory

```bash
ansible-inventory -i yc_inventory.yml --list
ansible-inventory -i yc_inventory.yml --graph --vars
```

### With playbooks

```bash
ansible-playbook -i yc_inventory.yml playbook.yml
```

### Connection and `ansible_user`

The plugin does not set the connection user: if `ansible_user` is not defined
anywhere, Ansible connects as the local user of the controller, not as the user
of the image. For VMs created through the CLI that is usually `yc-user`, for
Ubuntu images `ubuntu`. This is Ansible behaviour, not a plugin defect: the name
is set in the playbook (`remote_user`), with `-u`, or in `group_vars`.

Keep the precedence order in mind: the `ansible_user` label is a host variable,
so it **overrides** both `remote_user` and `-u`
(`play_context.set_task_and_variable_override()`: task attributes are applied
first, then magic variables from the inventory).

### With `ansible.cfg`

```ini
[defaults]
# The plugin path goes into [defaults]; Ansible does not read this key in [inventory].
inventory_plugins = ./inventory_plugins

[inventory]
# yaml is mandatory: without it a regular static inventory is not parsed.
enable_plugins = yandex_cloud_inventory, yaml, ini, script, host_list
```

The `ansible.cfg` in the repository root is the config of the offline test
stand: it only sets the plugin path and `enable_plugins`, and the stand needs no
SSH. It is usable as a sample for a production config, but check the remaining
settings yourself: for example `host_key_checking` is deliberately not set here,
and disabling host key checking on a workstation is a separate decision rather
than a default.

## Grouping instances

The plugin creates groups from:

1. **Zones** — for example `ru_central1_a` (dashes become `_`);
2. **The `ansible_group` label** — the instance joins the group `yc_<value>`
   (`docker` becomes `yc_docker`, dashes become `_`);
3. **The `group` option** — if set, every host is added to that group.

### Labels

VM labels are untrusted data: anyone with access to the folder can set them.
That is why they never land in host variables as is:

- every label is exported as `yc_label_<key>` (`-` in the key becomes `_`, the
  value is kept unchanged): `role: web-app` → `yc_label_role = web-app`;
- only `ansible_user` and `ansible_port` become service variables (allowlist):
  they are applied as is and also duplicated as `yc_label_*`. Note that
  `ansible_user` is a host variable and therefore **overrides** `remote_user`
  and `-u`. Set a label with this key deliberately, otherwise "why did we
  connect as the wrong user" takes a long time to find;
- the allowlist values are validated: `ansible_port` must be a number from 1 to
  65535, `ansible_user` must be non-empty and free of spaces, quotes,
  backslashes and non-printable characters (both end up on the `ssh` command
  line, and a control sequence from a label would also reach the operator's
  terminal and CI logs). An unusable value is dropped with a warning and stays
  available as `yc_label_*`;
- other labels starting with `ansible_` are not applied — the plugin prints a
  warning with the VM name and the key. The reason: an `ansible_host` label
  would override the connection address, and `ansible_ssh_common_args` with a
  `ProxyCommand` would execute a command on the controller;
- two labels are directives rather than variables. Keys are normalised the same
  way as variable names, so `ansible-group` and `ansible_group` are the same
  label:
  - `ansible: false` — exclude the instance from the inventory (case does not
    matter);
  - `ansible_group: docker` — add the instance to the group `yc_docker`.
    The `yc_` prefix is **mandatory and not configurable**: without it a label
    would join groups you manage (`dbservers`, `prod`) and the host would get
    their `group_vars` — with secrets or with `ansible_connection: local`, that
    is, execution on the controller. On top of that, the group name becomes a
    path `group_vars/<name>`, and a label can be set by anyone with access to
    the folder: the value `../../outside/evil` read a file outside
    `group_vars`. Therefore:
    - `-` in the value becomes `_` (`web-app` → `yc_web_app`);
    - the rest must be letters, digits and `_` (up to 63 characters): otherwise
      the plugin prints a warning with the VM name and the value, does **not**
      create the group, and the host stays in the inventory (zone and the
      `group` option are unaffected);
    - if the value already starts with `yc_`, the plugin does not guess:
      `ansible_group: yc_docker` yields `yc_yc_docker` plus a warning in the log;
    - the raw value stays visible in `yc_label_ansible_group`.

The plugin also warns when a VM has no IPv4 address and when two label keys
collide after normalisation (`a-b` and `a_b`). Separately, there is a safeguard
against a duplicate host name in the API response: Yandex Cloud requires VM
names to be unique inside a folder, so that warning is aimed at an API failure
rather than at a normal scenario (the test stand does not cover it — it cannot
be reproduced; see [`docs/upstream-differences.md`](docs/upstream-differences.md),
section 7).

### Host variables

The host name is the VM name in Yandex Cloud as is, dashes included: the VM
`web-1` is called `web-1` in the inventory, and `ansible web-1 -m ping` finds
it. Such variables cannot be read with dot notation (Jinja parses `web-1` as a
subtraction) — use `hostvars['web-1']`.

| Variable | Value |
|---|---|
| `ansible_host` | public IP if there is one, otherwise the internal one |
| `ipv4` | public IP, or `null` when there is no public address |
| `private_ipv4` | internal IP |
| `yc_name` | instance name in Yandex Cloud |
| `yc_label_<key>` | VM label (for example `role: web-app` → `yc_label_role`) |

Labels cannot override the service variables from the table: every label goes to
`yc_label_*` only. The exception is the `ansible_user`/`ansible_port` allowlist
(see "Labels").

## Upgrading from older versions

In 2.0 labels stopped being host variables directly (`role` → `yc_label_role`),
in 3.0 the host name is no longer normalised (`web_1` → `web-1`) and groups from
labels got the mandatory `yc_` prefix. The "before → after" tables and the
migration order are in
[`docs/upstream-differences.md`](docs/upstream-differences.md), sections 5 and 6
(Russian).

## Limitations

- The `cache` parameter of `parse()` is accepted for compatibility with the
  Ansible interface but is not used: the inventory is requested from the API on
  every run.
- Only the first network interface of a VM is used.
- The plugin does not look at the VM state: a stopped or preempted machine stays
  in the inventory as long as it exists as a resource.
- If the API refuses (expired IAM token, insufficient permissions), Ansible
  prints a warning and continues with an **empty** inventory — that is how
  source parsing works. The plugin prints the reason and a hint, but the exit
  code stays successful; in automation, check that the inventory is not empty.
- Groups `yc_*` are the label namespace, not yours: they are created by
  `ansible_group`, and foreign groups (for example `dbservers`) are unreachable
  through labels. The flip side: do not keep secrets in `group_vars/yc_*` — any
  VM in the folder can create such a group and receive those variables.

The full list of deliberate limitations is in
[`docs/upstream-differences.md`](docs/upstream-differences.md), section 7
(Russian).

## Requirements

- Python 3.11+
- ansible-core 2.18.18+ (2.18.18 is the first patch of the branch without
  CVE-2026-11332)
- yandexcloud >= 0.99.0, < 1.0 (verified on 0.99…0.412)

The versions verified for the test stand are pinned in `requirements-test.txt`
(`ansible-core==2.19.14`, `yandexcloud==0.412.0`).

## Testing without a cloud

The stand replaces the SDK with a stub (`tests/fake_yc/`) and runs the real
`ansible-inventory` through eighteen scenarios — from labels and addresses to
pagination, `verify_file`, API failures, label-driven injection and a missing
SDK. There are 127 assertions in total: on a regression the script exits
non-zero and prints which assertion failed. What exactly is covered is described
in [`docs/upstream-differences.md`](docs/upstream-differences.md), section 8
(Russian).

```bash
./bootstrap.sh        # builds a local .venv
./tests/run-tests.sh  # runs the scenarios
```

The stand ships in the sdist: the plugin can be verified from the built archive
without cloud access and without cloning the repository.

The same commands run in CI (GitHub Actions,
[`.github/workflows/tests.yml`](.github/workflows/tests.yml)): on Python 3.11,
3.12 and 3.13, plus a separate job from the unpacked sdist so that a file
missing from `MANIFEST.in` does not go unnoticed.

## Verified on a real cloud

Besides the stand, the behaviour was verified against a live Yandex Cloud folder
(labels, `ansible_user` precedence, dashed names, `group_vars`); details are in
[`docs/upstream-differences.md`](docs/upstream-differences.md), section 8
(Russian).

Your own folder can be checked with
[`tests/live-check.sh`](tests/live-check.sh) — it only reads the cloud:
`LIVE_INVENTORY=secrets/live_yc_inventory.yml ./tests/live-check.sh`.

## License

MIT — see [LICENSE](LICENSE). The upstream code is by Maksim Zatolokin; the
fixes and packaging of the fork are by
[morgenvor](https://github.com/morgenvor).

## Support

Report fork issues in the `morgenvor/ansible-yandex-cloud-inventory`
repository. Report issues of the original plugin upstream.