#!/usr/bin/env python3
"""Unprivileged maintenance. Never follow links or remove directories."""
import fnmatch
import json
import os
from pathlib import Path
import pwd
import re
import stat
import sys
import time

PATTERNS = {'logs': ['*.log', '*.log.[0-9]*', '*.log.gz'], 'temp': ['*.tmp', '*.temp'], 'recycle': ['*']}
RECYCLE_NAMES = {'.recycle', '#recycle', '@recycle', '$RECYCLE.BIN', 'recycle', 'Recycle', '回收站'}
MAX_SCAN = 50000


def open_dir(path, base_fd=None):
    """Open every component without following symbolic links."""
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY) if base_fd is None else os.dup(base_fd)
    try:
        for part in str(path).split('/'):
            if part in ('', '.'):
                continue
            if part == '..':
                raise ValueError('目录不能包含 ..')
            next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd); fd = next_fd
        return fd
    except BaseException:
        os.close(fd)
        raise


def scope(user, value, mode):
    requested = Path(value)
    if not requested.is_absolute() or '..' in requested.parts:
        raise ValueError('请选择明确的绝对目录，不允许 ..')
    target = requested.resolve(strict=True)
    data = Path('/nas/pool0') / user / 'data'
    plugin = Path('/home') / user / 'plugin'
    allowed = data in target.parents
    if not allowed:
        # Only a plugin's var directory; not scripts, INFO, etc or its entire root.
        try:
            relative = target.relative_to(plugin)
            allowed = len(relative.parts) >= 2 and relative.parts[1] == 'var'
        except ValueError:
            pass
    if not allowed:
        raise ValueError('只允许当前用户文件区的子目录，或当前用户插件的 var 目录；不允许文件区根目录、系统目录和 Docker 数据目录')
    if mode == 'recycle' and target.name not in RECYCLE_NAMES:
        raise ValueError('回收站模板只接受名称为 .recycle、#recycle、@recycle、$RECYCLE.BIN、recycle、Recycle 或 回收站 的明确目录')
    if data in target.parents and not os.path.ismount('/nas/pool0'):
        raise ValueError('存储池未挂载，拒绝清理')
    return str(target)


def fingerprint(s):
    return [s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns]


def scan(fd, params, uid):
    root = os.fstat(fd)
    cutoff = time.time()-params['days']*86400
    deadline = time.monotonic()+8
    results = []; visited = 0; total = 0
    def walk(directory, relative, depth):
        nonlocal visited, total
        if depth > 32:
            raise ValueError('目录过深，拒绝清理，请缩小目标范围')
        with os.scandir(directory) as entries:
            for entry in entries:
                visited += 1
                if visited > MAX_SCAN or time.monotonic() > deadline:
                    raise ValueError('扫描范围过大或超过 8 秒，请选择更小的目录')
                info = entry.stat(follow_symlinks=False)
                if info.st_dev != root.st_dev or stat.S_ISLNK(info.st_mode):
                    continue
                rel = relative+[entry.name]
                if stat.S_ISDIR(info.st_mode) and params.get('recursive', True):
                    child = os.open(entry.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
                    try:
                        actual = os.fstat(child)
                        if (actual.st_dev, actual.st_ino) != (info.st_dev, info.st_ino):
                            raise ValueError('扫描期间目录发生变化，请重试')
                        walk(child, rel, depth+1)
                    finally:
                        os.close(child)
                elif stat.S_ISREG(info.st_mode) and info.st_uid == uid and info.st_nlink == 1 and info.st_mtime < cutoff:
                    if any(fnmatch.fnmatch(entry.name, p) for p in PATTERNS[params['mode']]):
                        results.append({'parts': rel, 'identity': fingerprint(info), 'size': info.st_size})
                        total += info.st_size
                        if len(results) > params['maxFiles'] or total > params['maxMiB']*1048576:
                            raise ValueError('预计删除量超过本任务的文件数/容量上限；未删除任何文件，请缩小范围或调整上限后重新预览')
    walk(fd, [], 0)
    return results


def clean_directory(path, params, uid, approval=None):
    fd = open_dir(path)
    try:
        root = os.fstat(fd)
        identity = [root.st_dev, root.st_ino]
        if approval is not None and approval.get('root') != identity:
            raise ValueError('目标目录或挂载已改变，必须重新预览并确认')
        files = scan(fd, params, uid)
        result = {'root': identity, 'path': path, 'count': len(files), 'bytes': sum(f['size'] for f in files),
                  'samples': ['/'.join(f['parts']) for f in files[:40]], 'patterns': PATTERNS[params['mode']]}
        if approval is None:
            return result
        removed = 0; removed_bytes = 0; skipped = 0; errors = []
        for item in files:
            parent = None
            try:
                parent = open_dir('/'.join(item['parts'][:-1]), fd)
                name = item['parts'][-1]
                current = os.stat(name, dir_fd=parent, follow_symlinks=False)
                if fingerprint(current) != item['identity'] or current.st_uid != uid or current.st_nlink != 1 or not stat.S_ISREG(current.st_mode):
                    skipped += 1
                    continue
                os.unlink(name, dir_fd=parent)
                removed += 1; removed_bytes += item['size']
            except OSError as error:
                if len(errors) < 10:
                    errors.append('/'.join(item['parts'])+': '+str(error))
                skipped += 1
            finally:
                if parent is not None:
                    os.close(parent)
        result.update(removed=removed, removedBytes=removed_bytes, skipped=skipped, errors=errors)
        return result
    finally:
        os.close(fd)


def main():
    user = sys.argv[1]
    if not re.fullmatch(r'u[0-9]+', user):
        raise ValueError('无效用户')
    account = pwd.getpwnam(user)
    if account.pw_uid == 0:
        raise ValueError('维护操作不允许使用 root')
    if os.geteuid() == 0:
        os.initgroups(user, account.pw_gid); os.setgid(account.pw_gid); os.setuid(account.pw_uid)
    if os.geteuid() != account.pw_uid:
        raise ValueError('执行身份不匹配')
    os.chdir('/')
    req = json.loads(sys.stdin.buffer.read(65537))
    if req['action'] == 'conditions':
        for path in req.get('paths', []):
            if not os.path.isdir(path) or not os.access(path, os.R_OK | os.X_OK):
                raise ValueError('目标目录未就绪或当前用户不可访问：'+path)
        result = {'ready': True}
    else:
        params = req['params']
        path = scope(user, params['path'], params['mode'])
        result = clean_directory(path, params, account.pw_uid, req.get('approval'))
    print(json.dumps(dict(result, ok=True), ensure_ascii=False))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(json.dumps({'ok': False, 'error': str(error)}, ensure_ascii=False))
        sys.exit(1)
