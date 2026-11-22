"""Read-only gh transport and strict paginated response validation."""
import json
import subprocess


def require(check, message):
    if not check:
        raise ValueError(message)


def gh(*args):
    return json.loads(subprocess.check_output(['gh', 'api', '--hostname', 'github.com', *args], timeout=90))


def pages(endpoint, field=None):
    data = gh('--paginate', '--slurp', endpoint)
    require(isinstance(data, list) and data, f'no pages: {endpoint}')
    rows = []
    for page in data:
        part = page[field] if field else page
        require(isinstance(part, list), f'incomplete page: {endpoint}')
        rows.extend(part)
    if field:
        require(all(page['total_count'] == len(rows) for page in data), f'incomplete results: {endpoint}')
    return rows


def positive(n):
    require(type(n) is int and n > 0, 'invalid positive integer')
    return n
