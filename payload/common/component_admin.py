#!/usr/bin/python3
"""Install/remove shared component registrations. Called only by root installers."""
import argparse
import contextlib
import datetime
import fcntl
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import privileged_runtime as runtime

BASE = runtime.BASE
BACKUPS = Path('/data/.minas-privileged-backups')
SUDOERS = Path('/etc/sudoers.d')
CRON = Path('/etc/cron.d')
LEGACY = [Path('/data/plugin/.taskcenter-system'), Path('/data/.taskcenter-system')]
CORE_FILES = ('minas-helper', 'privileged_runtime.py', 'component_admin.py', 'docker-manager-helper')
TASK_FILES = ('task-center-helper', 'task_schedule.py', 'task_maintenance.py')
MIGRATION_MARK = 'MIGRATED_TO_COMMON'


def atomic(path, data, mode=0o600):
    if isinstance(data, dict):
        data = json.dumps(data, ensure_ascii=False, indent=2).encode()
    if isinstance(data, str): data = data.encode()
    if path.is_symlink(): raise ValueError('拒绝覆盖符号链接：%s' % path)
    fd, tmp = tempfile.mkstemp(prefix='.' + path.name + '.', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(data); os.fchmod(f.fileno(), mode); os.fchown(f.fileno(), 0, 0)
            f.flush(); os.fsync(f.fileno())
        os.replace(tmp, str(path))
    finally:
        if os.path.exists(tmp): os.unlink(tmp)


def version(value):
    if not re.fullmatch(r'\d+\.\d+\.\d+', value): raise ValueError('无效组件版本')
    return tuple(map(int, value.split('.')))


def validate_tree(directory):
    for path in [directory] + list(directory.rglob('*')):
        s = path.lstat()
        if s.st_uid != 0 or s.st_mode & 0o022 or not (stat.S_ISREG(s.st_mode) or stat.S_ISDIR(s.st_mode)):
            raise ValueError('调度数据包含链接、不安全权限或非 root 文件：%s' % path)


def check_idle():
    # The component exclusive lock already excludes current shared workers.
    for directory in [BASE] + LEGACY:
        users = directory / 'users'
        if not users.is_dir(): continue
        for file in users.glob('u*/state.json'):
            state = json.loads(file.read_text())
            for run in state.get('runs', []):
                if run.get('state') == 'running':
                    pid = run.get('pid')
                    if pid and Path('/proc/%s' % int(pid)).exists():
                        raise ValueError('存在执行中的定时任务，稍后再更新')
                    # Do not silently classify a just-reserved worker as dead.
                    import time
                    if time.time() - run.get('started', 0) < 90:
                        raise ValueError('存在刚提交的定时任务，稍后再更新')
    for file in [Path('/run/dockermanager-upgrade-status.json'), Path('/run/dockermanager-bulk-status.json')]:
        if not file.is_file(): continue
        data = json.loads(file.read_text())
        if data.get('state') == 'running' and data.get('pid') and Path('/proc/%s' % int(data['pid'])).exists():
            raise ValueError('Docker 正在升级或批量操作，稍后再安装')


@contextlib.contextmanager
def migration(user, backup):
    target = BASE / 'users' / user
    source = next((d / 'users' / user for d in reversed(LEGACY)
                   if (d / 'users' / user / 'state.json').is_file()
                   and not (d / 'users' / user / MIGRATION_MARK).exists()
                   and not (d / 'users' / user / 'MIGRATED_TO_V02').exists()), None)
    if target.exists() or source is None:
        yield
        return
    validate_tree(source)
    fd = os.open(str(source / 'lock'), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    old = None
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        old = (source / 'state.json').read_bytes()
        state = json.loads(old)
        if any(r.get('state') == 'running' for r in state.get('runs', [])):
            raise ValueError('旧版任务记录仍处于执行中，请先确认任务结束')
        shutil.copytree(str(source), str(backup / 'legacy-state'))
        atomic(backup / 'legacy-source.json', {'path': str(source)})
        runtime.secure_directory(BASE / 'users', create=True, mode=0o700)
        # Target name becomes visible only after old scheduler has been disabled.
        staging = Path(tempfile.mkdtemp(prefix='.' + user + '-', dir=str(BASE / 'users')))
        staging.rmdir()
        shutil.copytree(str(source), str(staging))
        state['scheduler'] = False
        atomic(source / 'state.json', state)
        os.replace(str(staging), str(target))
        try:
            yield
            atomic(source / MIGRATION_MARK, str(target) + '\n')
        except BaseException:
            atomic(source / 'state.json', old)
            if target.exists(): shutil.rmtree(str(target))
            raise
    finally:
        os.close(fd)


def install_sudo(user, plugin):
    rule = '%s ALL=(root) NOPASSWD: %s/minas-helper %s\n' % (user, BASE, plugin)
    fd, temp = tempfile.mkstemp(prefix='.minas-sudo-', dir=str(SUDOERS))
    os.close(fd); temp = Path(temp)
    try:
        atomic(temp, rule, 0o440)
        subprocess.run(['/usr/sbin/visudo', '-cf', str(temp)], check=True, stdout=subprocess.DEVNULL)
        os.replace(str(temp), str(SUDOERS / (plugin + '-' + user)))
    finally:
        if temp.exists(): temp.unlink()


def update_cron(data):
    plugins = {p for grants in data['users'].values() for p in grants}
    file = CRON / 'minas-privileged'
    if plugins:
        text = 'SHELL=/bin/sh\nPATH=/usr/sbin:/usr/bin:/sbin:/bin:/data/docker\nMAILTO=""\n'
        if 'taskcenter' in plugins:
            text += '* * * * * root %s/minas-helper taskcenter tick >/dev/null 2>&1\n' % BASE
        if 'dockermanager' in plugins:
            text += '@reboot root %s/minas-helper boot >/dev/null 2>&1\n' % BASE
        atomic(file, text, 0o644)
    elif file.exists(): file.unlink()
    # Retain legacy cron only when an unmigrated account still needs it.
    remaining = any(not (f.parent / MIGRATION_MARK).exists() and not (f.parent / 'MIGRATED_TO_V02').exists()
                    for d in LEGACY for f in (d / 'users').glob('u*/state.json'))
    old = CRON / 'taskcenter'
    if not remaining and old.is_file() and 'task-center-helper' in old.read_text(): old.unlink()


def install(payload, plugin, user, plugin_version, backup):
    source = payload / 'common'
    old = runtime.registry() if (BASE / 'registry.json').exists() else {'apiVersion': 1, 'version': '0.0.0', 'users': {}, 'modules': {}}
    if version(old['version'])[0] != 0 and version(old['version'])[0] != runtime.API_VERSION:
        raise ValueError('公共权限组件主版本不兼容')
    if version(old.get('modules', {}).get(plugin, '0.0.0')) > version(plugin_version):
        raise ValueError('已安装更新的插件权限模块，拒绝降级')
    data = json.loads(json.dumps(old))
    if version(old['version']) <= version(runtime.VERSION):
        for name in CORE_FILES:
            file = source / name
            if not file.is_file(): raise ValueError('安装包缺少公共组件：' + name)
        for name in CORE_FILES:
            atomic(BASE / name, (source / name).read_bytes(), 0o755 if name in ('minas-helper', 'component_admin.py', 'docker-manager-helper') else 0o644)
        data['version'] = runtime.VERSION
    if plugin == 'taskcenter':
        for name in TASK_FILES:
            atomic(BASE / name, (payload / 'system' / name).read_bytes(), 0o755 if name == 'task-center-helper' else 0o644)
    data['users'].setdefault(user, [])
    if plugin not in data['users'][user]: data['users'][user].append(plugin)
    data.setdefault('modules', {})[plugin] = plugin_version
    atomic(BASE / 'registry.json', data)
    with migration(user, backup) if plugin == 'taskcenter' else contextlib.nullcontext():
        if plugin == 'taskcenter':
            sys.path.insert(0, str(BASE))
            loader = importlib.machinery.SourceFileLoader('install_tasks', str(BASE / 'task-center-helper'))
            spec = importlib.util.spec_from_loader(loader.name, loader)
            module = importlib.util.module_from_spec(spec); loader.exec_module(module)
            module.initialize(user)
            # Validate, but do not rewrite, existing task settings or enabled flags.
            state = json.loads((BASE / 'users' / user / 'state.json').read_text())
            for task in state['tasks']: module.validate_task(task)
        install_sudo(user, plugin)
    obsolete = CRON / ('dockermanager-' + user)
    if plugin == 'dockermanager' and obsolete.exists(): obsolete.unlink()
    update_cron(data)
    return data


def remove(plugin, user, backup):
    data = runtime.registry()
    grants = data['users'].get(user, [])
    if plugin == 'taskcenter':
        target = BASE / 'users' / user
        if target.exists():
            validate_tree(target)
            shutil.copytree(str(target), str(backup / 'removed-state'))
            # Exact validated single-user state, never the user's files or containers.
            shutil.rmtree(str(target))
    if plugin in grants: grants.remove(plugin)
    if not grants: data['users'].pop(user, None)
    atomic(BASE / 'registry.json', data)
    rule = SUDOERS / (plugin + '-' + user)
    if rule.exists(): rule.unlink()
    update_cron(data)
    # Keep shared code while any user/plugin is registered. Empty scaffolding is
    # harmless; remove known code only, never unknown files or backup directories.
    if not data['users']:
        for name in CORE_FILES + TASK_FILES:
            file = BASE / name
            if file.is_file(): file.unlink()
        for directory in (BASE / 'users',):
            if directory.is_dir():
                try: directory.rmdir()
                except OSError: pass
    return data


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['install', 'remove'])
    parser.add_argument('--plugin', choices=sorted(runtime.MODULES), required=True)
    parser.add_argument('--user', required=True)
    parser.add_argument('--payload', type=Path)
    parser.add_argument('--plugin-version', default='0.0.0')
    args = parser.parse_args()
    if os.geteuid() != 0 or os.environ.get('SUDO_USER') not in (None, 'root'):
        raise ValueError('组件管理仅允许 root 安装器调用')
    runtime.account(args.user)
    runtime.secure_directory(BASE, create=True)
    runtime.secure_directory(BACKUPS, create=True, mode=0o700)
    with runtime.lock('component.lock', exclusive=True):
        check_idle()
        backup = Path(tempfile.mkdtemp(prefix=datetime.datetime.now().strftime('%Y%m%d-%H%M%S-'), dir=str(BACKUPS)))
        saved = backup / 'component'
        shutil.copytree(str(BASE), str(saved), ignore=shutil.ignore_patterns('*.lock'))
        rule = SUDOERS / (args.plugin + '-' + args.user)
        if rule.exists(): shutil.copy2(str(rule), str(backup / 'sudoers'))
        for file in CRON.glob('*'):
            if file.is_file() and file.name in {'minas-privileged', 'taskcenter', 'dockermanager-' + args.user}:
                shutil.copy2(str(file), str(backup / ('cron-' + file.name)))
        try:
            data = install(args.payload, args.plugin, args.user, args.plugin_version, backup) if args.action == 'install' else remove(args.plugin, args.user, backup)
        except BaseException:
            # Restore files changed by the component transaction. Installer frontend
            # has not been replaced yet. Legacy migration restores its own state.
            for file in BASE.iterdir():
                if file.is_file() and file.name not in {'component.lock', 'docker.lock'} and not (saved / file.name).exists(): file.unlink()
            for file in saved.iterdir():
                if file.is_file(): atomic(BASE / file.name, file.read_bytes(), file.stat().st_mode & 0o777)
            user_state = BASE / 'users' / args.user
            if user_state.exists():
                validate_tree(user_state)
                shutil.rmtree(str(user_state))
            previous_state = saved / 'users' / args.user
            if previous_state.exists():
                (BASE / 'users').mkdir(mode=0o700, exist_ok=True)
                shutil.copytree(str(previous_state), str(user_state))
            if (backup / 'legacy-source.json').exists():
                legacy = Path(json.loads((backup / 'legacy-source.json').read_text())['path'])
                if legacy not in [p / 'users' / args.user for p in LEGACY]:
                    raise ValueError('无效恢复路径')
                atomic(legacy / 'state.json', (backup / 'legacy-state/state.json').read_bytes())
                if (legacy / MIGRATION_MARK).exists(): (legacy / MIGRATION_MARK).unlink()
            if (backup / 'sudoers').exists(): atomic(rule, (backup / 'sudoers').read_bytes(), 0o440)
            elif rule.exists(): rule.unlink()
            for name in ['minas-privileged', 'taskcenter', 'dockermanager-' + args.user]:
                saved_cron = backup / ('cron-' + name)
                if saved_cron.exists(): atomic(CRON / name, saved_cron.read_bytes(), 0o644)
                elif (CRON / name).exists(): (CRON / name).unlink()
            raise
    subprocess.run(['/usr/bin/systemctl', 'reload', 'crond.service'], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(json.dumps({'ok': True, 'helperVersion': data['version'], 'backup': str(backup), 'registeredUsers': len(data['users'])}, ensure_ascii=False))


if __name__ == '__main__':
    try: main()
    except Exception as error:
        print('公共权限组件安装/卸载失败：%s' % error, file=sys.stderr)
        sys.exit(1)
