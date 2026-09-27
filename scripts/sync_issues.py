#!/usr/bin/env python3
"""Синхронизация меток, milestones и issues с scripts/modules.json.

Запускается в GitHub Actions (workflow «Синхронизировать issues») и работает с тем репозиторием,
в котором запущен: для копии программы — с копией. Нужны переменные окружения
GITHUB_REPOSITORY (owner/name) и GITHUB_TOKEN. Для проверки без изменений: --dry-run.

Правила безопасности:
- существующий issue ищется только по пути к файлу модуля в описании (blob/main/<путь>);
  если путь найден в двух issues — оба пропускаются с предупреждением;
- каждое изменение — отдельный запрос к одному issue; между запросами пауза;
- отмеченные галочки в описании сохраняются; закрытые issues не открываются.
"""
import json, os, re, sys, time, urllib.request, urllib.error

API = os.environ.get('GITHUB_API_URL', 'https://api.github.com')
REPO = os.environ['GITHUB_REPOSITORY']
TOKEN = os.environ.get('GITHUB_TOKEN', '')
DRY = '--dry-run' in sys.argv
PAUSE = float(os.environ.get('SYNC_PAUSE', '1.0'))
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

OWNER, NAME = REPO.split('/')
SITE = f'https://{OWNER.lower()}.github.io/{NAME}/'
BLOB = f'https://github.com/{REPO}/blob/main/'

CHECKLIST = [
    'Проверил готовность: темы из раздела «Готовность к модулю» знакомы или пройдены',
    'Прочитал урок',
    'Сделал практику',
    'Ответил вслух на все вопросы для самопроверки, без подглядывания',
    'Записал выводы своими словами в раздел «Заметки»',
]
# прежние формулировки пунктов -> новые (чтобы не потерять отмеченные галочки)
ALIASES = {'Прочитал материалы из раздела «Читать»': 'Прочитал урок'}


def call(method, url, data=None):
    if not url.startswith('http'):
        url = f'{API}/repos/{REPO}/{url}'
    body = json.dumps(data).encode() if data is not None else None
    for attempt in range(6):
        req = urllib.request.Request(url, data=body, method=method, headers={
            'Accept': 'application/vnd.github+json', 'Authorization': f'Bearer {TOKEN}',
            'X-GitHub-Api-Version': '2022-11-28', 'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(req) as r:
                raw = r.read()
                return json.loads(raw) if raw else None, r.headers
        except urllib.error.HTTPError as e:
            text = e.read().decode(errors='replace')
            if e.code in (403, 429) and ('rate limit' in text.lower() or e.headers.get('Retry-After')):
                wait = int(e.headers.get('Retry-After') or 60)
                print(f'  лимит запросов, жду {wait} с'); time.sleep(wait); continue
            if e.code >= 500 and attempt < 5:
                time.sleep(5); continue
            raise SystemExit(f'Ошибка {e.code} {method} {url}: {text[:300]}')
    raise SystemExit(f'Не удалось выполнить {method} {url}')


def get_all(path):
    out, url = [], f'{API}/repos/{REPO}/{path}{"&" if "?" in path else "?"}per_page=100'
    while url:
        data, headers = call('GET', url)
        out += data
        m = re.search(r'<([^>]+)>;\s*rel="next"', headers.get('Link') or '')
        url = m.group(1) if m else None
    return out


def write(method, path, data, what):
    print(('[dry-run] ' if DRY else '') + what)
    if DRY:
        return None
    res, _ = call(method, path, data)
    time.sleep(PAUSE)
    return res


def page_url(path):
    return SITE + re.sub(r'\.md$', '.html', path)


def make_body(i, index):
    lines = [f'**Материал:** {page_url(i["path"])}',
             f'**Исходник:** [`{i["path"]}`]({BLOB}{i["path"]})',
             f'**Неделя:** {i["week"]}', '', '## Готовность', '']
    if i.get('prereq'):
        refs = ', '.join(f'[{index[p]["title"].split(":")[0]}]({page_url(index[p]["path"])})' for p in i['prereq'])
        lines += [f'Модуль опирается на: {refs}.', '']
    lines += [f'- [ ] {c}' for c in CHECKLIST]
    lines += ['', 'Закрыть коммитом с заметками: `Closes #<номер этого issue>`.', '']
    return '\n'.join(lines)


def carry_ticks(old_body, new_body):
    done = set()
    for m in re.finditer(r'^\s*[-*] \[[xX]\] (.+?)\s*$', old_body or '', re.M):
        t = m.group(1)
        done.add(ALIASES.get(t, t))
    return re.sub(r'^- \[ \] (.+)$', lambda m: f'- [x] {m.group(1)}' if m.group(1) in done else m.group(0), new_body, flags=re.M)


def patch_config():
    """В копии программы подставляет её адреса в _config.yml. Возвращает True, если файл изменён."""
    p = os.path.join(ROOT, '_config.yml')
    s = open(p, encoding='utf-8').read()
    new = re.sub(r'^url: .*$', f'url: https://{OWNER.lower()}.github.io', s, flags=re.M)
    new = re.sub(r'^baseurl: .*$', f'baseurl: /{NAME}', new, flags=re.M)
    new = re.sub(r'https://github\.com/[\w.-]+/[\w.-]+(?=\s*$)', f'https://github.com/{REPO}', new, flags=re.M)
    if new != s:
        print('_config.yml: адреса заменены на ' + REPO)
        if not DRY:
            open(p, 'w', encoding='utf-8').write(new)
        return True
    return False


def main():
    data = json.load(open(os.path.join(ROOT, 'scripts', 'modules.json'), encoding='utf-8'))
    index = {i['id']: i for i in data['issues']}
    if '--config' in sys.argv:
        patch_config()

    labels = {l['name']: l for l in get_all('labels')}
    for l in data['labels']:
        cur = labels.get(l['name'])
        if not cur:
            write('POST', 'labels', l, f'метка создана: {l["name"]}')
        elif cur.get('color') != l['color'] or (cur.get('description') or '') != l['description']:
            write('PATCH', f'labels/{urllib.request.quote(l["name"])}', {'color': l['color'], 'description': l['description']},
                  f'метка обновлена: {l["name"]}')

    ms = {m['title']: m for m in get_all('milestones?state=all')}
    for m in data['milestones']:
        if m['title'] not in ms:
            res = write('POST', 'milestones', {'title': m['title'], 'description': m['description']}, f'milestone создан: {m["title"]}')
            ms[m['title']] = res or {'number': None, 'title': m['title']}
    ours = {l['name'] for l in data['labels']}

    issues = [x for x in get_all('issues?state=all') if 'pull_request' not in x]
    by_path = {}
    for x in issues:
        for p in set(re.findall(r'blob/main/(\S+?\.md)', x.get('body') or '')):
            by_path.setdefault(p, []).append(x)

    created = updated = same = skipped = 0
    for i in data['issues']:
        found = by_path.get(i['path'], [])
        if len(found) > 1:
            print(f'ВНИМАНИЕ: путь {i["path"]} найден в нескольких issues: ' + ', '.join(f'#{x["number"]}' for x in found) + ' — пропускаю')
            skipped += 1
            continue
        body = make_body(i, index)
        mnum = ms[i['milestone']]['number']
        if not found:
            payload = {'title': i['title'], 'body': body, 'labels': [i['label']]}
            if mnum:
                payload['milestone'] = mnum
            write('POST', 'issues', payload, f'создан: {i["title"]}')
            created += 1
            continue
        x = found[0]
        patch = {}
        if x['title'] != i['title']:
            patch['title'] = i['title']
        if (x.get('milestone') or {}).get('number') != mnum and mnum:
            patch['milestone'] = mnum
        names = [l['name'] for l in x.get('labels', [])]
        want = [n for n in names if n not in ours] + [i['label']]
        if sorted(want) != sorted(names):
            patch['labels'] = want
        new_body = carry_ticks(x.get('body'), body)
        if (x.get('body') or '').replace('\r\n', '\n').strip() != new_body.strip():
            patch['body'] = new_body
        if patch:
            write('PATCH', f'issues/{x["number"]}', patch, f'обновлён #{x["number"]} ({", ".join(patch)}): {i["title"]}')
            updated += 1
        else:
            same += 1
    print(f'\nИтого: создано {created}, обновлено {updated}, без изменений {same}, пропущено {skipped}.')
    if skipped:
        sys.exit(2)


if __name__ == '__main__':
    main()
