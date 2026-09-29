"""Validated, minute-granularity schedules; no shell cron expansion."""
import datetime as dt
import functools
import re


def integer(value, low, high):
    if isinstance(value, bool) or not re.fullmatch(r'[0-9]+', str(value)):
        raise ValueError('请输入整数')
    result = int(value)
    if not low <= result <= high:
        raise ValueError('数值必须在 %s–%s 之间' % (low, high))
    return result


def clock(value):
    if not re.fullmatch(r'([01][0-9]|2[0-3]):[0-5][0-9]', str(value)):
        raise ValueError('执行时间格式应为 HH:MM')
    return value


@functools.lru_cache(maxsize=128)
def cron(expression):
    fields = expression.split()
    if len(fields) != 5 or len(expression) > 160:
        raise ValueError('Cron 必须为 5 段：分 时 日 月 周')
    result = []
    for field, (low, high) in zip(fields, [(0, 59), (0, 23), (1, 31), (1, 12), (0, 7)]):
        values = set()
        for piece in field.split(','):
            parts = piece.split('/')
            if len(parts) > 2:
                raise ValueError('Cron 步长无效')
            base = parts[0]
            step = integer(parts[1], 1, high-low+1) if len(parts) == 2 else 1
            if base == '*':
                start, end = low, high
            elif '-' in base:
                bounds = base.split('-')
                if len(bounds) != 2:
                    raise ValueError('Cron 范围无效')
                start, end = integer(bounds[0], low, high), integer(bounds[1], low, high)
            else:
                start = integer(base, low, high)
                end = high if len(parts) == 2 else start
            if start > end:
                raise ValueError('Cron 范围不能倒序')
            values.update(range(start, end+1, step))
        result.append(frozenset(values))
    result[4] = frozenset(v % 7 for v in result[4])
    return tuple(result), (fields[2].startswith('*'), fields[4].startswith('*'))


def validate(s):
    typ = s.get('type')
    out = {'type': typ}
    if typ in ('daily', 'weekly', 'workdays', 'weekends', 'monthly'):
        out['time'] = clock(s.get('time'))
        if typ in ('weekly', 'workdays', 'weekends'):
            days = list(range(5)) if typ == 'workdays' else [5, 6] if typ == 'weekends' else s.get('days', [s.get('weekday', 0)])
            if not isinstance(days, list) or not 1 <= len(days) <= 7:
                raise ValueError('请至少选择一个星期')
            out.update(type='weekly', days=sorted(set(integer(d, 0, 6) for d in days)))
        if typ == 'monthly':
            out['day'] = integer(s.get('day', 1), 1, 31)
    elif typ == 'once':
        value = str(s.get('at', ''))
        if not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}', value):
            raise ValueError('请选择一次性执行的日期和时间')
        dt.datetime.strptime(value, '%Y-%m-%dT%H:%M')
        out['at'] = value
    elif typ == 'interval':
        out['minutes'] = integer(s.get('minutes', 60), 1, 10080)
        if s.get('window'):
            start, end = clock(s.get('start')), clock(s.get('end'))
            if start > end:
                raise ValueError('时间窗口不能跨午夜，请拆分成两个任务')
            out.update(window=True, start=start, end=end)
    elif typ == 'boot':
        out['delay'] = integer(s.get('delay', 120), 60, 3600)
    elif typ == 'cron':
        out['expression'] = ' '.join(str(s.get('expression', '')).split())
        cron(out['expression'])
    elif typ == 'after_task':
        ident = str(s.get('taskId', ''))
        if not re.fullmatch(r'[a-f0-9]{32}', ident):
            raise ValueError('请选择前置任务')
        out['taskId'] = ident
    else:
        raise ValueError('不支持的计划类型')
    return out


def date_matches(s, local):
    typ = s['type']
    if typ == 'weekly':
        return local.weekday() in s.get('days', [s.get('weekday', 0)])
    if typ == 'monthly':
        return local.day == s['day']
    if typ == 'cron':
        fields, wild = cron(s['expression'])
        dom, dow = local.day in fields[2], (local.weekday()+1) % 7 in fields[4]
        return local.month in fields[3] and ((dom and dow) if any(wild) else (dom or dow))
    return True


def slot(task, now, boot, uptime):
    s = task['schedule']; typ = s['type']
    local = dt.datetime.fromtimestamp(now)
    if typ == 'after_task':
        return None
    if typ == 'boot':
        return 'boot:' + boot if uptime >= s['delay'] else None
    if typ == 'once':
        return s['at'] if local.strftime('%Y-%m-%dT%H:%M') == s['at'] else None
    if typ == 'interval':
        if s.get('window') and not s['start'] <= local.strftime('%H:%M') <= s['end']:
            return None
        minute = int(now//60)
        return str(minute) if minute % s['minutes'] == 0 else None
    if not date_matches(s, local):
        return None
    if typ == 'cron':
        fields, _ = cron(s['expression'])
        matches = local.minute in fields[0] and local.hour in fields[1]
    else:
        matches = local.strftime('%H:%M') == s['time']
    return local.strftime('%Y-%m-%d %H:%M') if matches else None


def upcoming(task, now, count=5):
    s = task['schedule']; typ = s['type']
    if typ in ('boot', 'after_task'):
        return []
    if typ == 'once':
        stamp = dt.datetime.strptime(s['at'], '%Y-%m-%dT%H:%M').timestamp()
        return [stamp] if stamp > now else []
    if typ == 'interval':
        step = s['minutes']*60
        stamp = (int(now)//step+1)*step
        result = []
        for _ in range(527040//s['minutes']+1):
            if slot(task, stamp, '', 0):
                result.append(stamp)
                if len(result) == count:
                    break
            stamp += step
        return result
    if typ == 'cron':
        fields, _ = cron(s['expression'])
        hours, minutes = sorted(fields[1]), sorted(fields[0])
    else:
        hour, minute = map(int, s['time'].split(':'))
        hours, minutes = [hour], [minute]
    result = []
    today = dt.datetime.fromtimestamp(now).date()
    # Enumerate matching days, not every minute; covers leap-day schedules.
    for offset in range(366*8+1):
        day = today+dt.timedelta(days=offset)
        if not date_matches(s, day):
            continue
        for hour in hours:
            for minute in minutes:
                local = dt.datetime.combine(day, dt.time(hour, minute))
                stamp = local.timestamp()
                if stamp > now and dt.datetime.fromtimestamp(stamp) == local:
                    result.append(stamp)
                    if len(result) == count:
                        return result
    return result
