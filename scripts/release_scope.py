"""Attribute issue closures to an exact release range, never to a milestone alone."""
from datetime import datetime
import html
import re

from release_api import gh, pages, positive, require


# Page the closing relationships and immutable closure events, not just PR keywords.
FIELDS = {
    'pullRequest': ('closingIssuesReferences', 'merged mergeCommit { oid } baseRefName body', 'number repository { nameWithOwner }'),
    'issue': ('timelineItems', 'title closedAt state stateReason', '''... on ClosedEvent { createdAt closer { __typename
              ... on Commit { oid repository { nameWithOwner } }
              ... on PullRequest { number merged mergeCommit { oid } repository { nameWithOwner } } } }'''),
}


def relationship(repo, kind, n):
    connection, fields, selected = FIELDS[kind]
    extra = ',itemTypes:[CLOSED_EVENT]' if kind == 'issue' else ''
    query = f'''query($owner:String!,$name:String!,$number:Int!,$cursor:String) {{repository(owner:$owner,name:$name) {{
      {kind}(number:$number) {{number repository {{nameWithOwner}} milestone {{number title}} {fields}
      {connection}(first:100,after:$cursor{extra}) {{nodes {{{selected}}} pageInfo {{endCursor hasNextPage}}}} }} }} }}'''
    owner, name = repo.split('/'); nodes, seen, identity = [], set(), None; cursor = None
    while True:
        data = gh('graphql','-f','query='+query,'-f','owner='+owner,'-f','name='+name,'-F',f'number={positive(n)}',
                  *(['-f','cursor='+cursor] if cursor else []))
        require('errors' not in data,'incomplete GraphQL response'); item = data['data']['repository'][kind].copy()
        page = item.pop(connection)
        require(item['number'] == n and item['repository']['nameWithOwner'].lower() == repo.lower() and
                (identity is None or identity == item), 'relationship changed during collection')
        identity = item
        require(isinstance(page['nodes'],list),'missing graph nodes'); nodes.extend(page['nodes']); info = page['pageInfo']
        if info['hasNextPage'] is False: return item, nodes
        cursor = info['endCursor']; require(info['hasNextPage'] is True and isinstance(cursor,str) and cursor and cursor not in seen,'incomplete graph page')
        seen.add(cursor)


def markdown(text):
    return re.sub(r'([\\`*_{}\[\]()#+.!|~<>])', r'\\\1', html.escape(' '.join(text.split()),quote=False))


REF = r'(?:https://github\.com/([\w.-]+/[\w.-]+)/issues/|(?:([\w.-]+/[\w.-]+))?#)([1-9][0-9]*)\b'
CLOSING = re.compile(r'\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+' + REF, re.I)
NEXT_REF = re.compile(r'\s*(?:,\s*(?:and\s+)?|and\s+)' + REF, re.I)


def closing_references(text, repo):
    refs = set()
    for m in CLOSING.finditer(text):
        while m:
            require((m[1] or m[2] or repo).lower() == repo.lower(), 'external closing reference')
            refs.add(int(m[3]))
            m = NEXT_REF.match(text, m.end())
    return refs


def release_scope(repo, tag, sha, commits, git):
    url = 'https://github.com/'+repo
    active=set(commits)
    ms = [m for m in pages(f'repos/{repo}/milestones?state=all&per_page=100') if m['title'] == tag]
    require(len(ms)==1,'missing or ambiguous release milestone'); mid=positive(ms[0]['number'])
    def in_milestone(item):
        m=item['milestone'];return m and m['number']==mid and m['title']==tag
    members=pages(f'repos/{repo}/issues?milestone={mid}&state=all&per_page=100')
    issues={positive(m['number']) for m in members if 'pull_request' not in m}
    milestone_prs = {positive(m['number']) for m in members if 'pull_request' in m}
    pulls=set(); linked=set(); merges={}
    for commit in commits:
        pulls.update(positive(p['number']) for p in pages(f'repos/{repo}/commits/{commit}/pulls?per_page=100'))
        body=git('show','-s','--format=%B',commit); linked.update(closing_references(body,repo))
        markers = re.findall(r'^This reverts commit ([0-9a-f]{40})(?:\.|, reversing)$',body,re.M)
        if markers and commit in active:
            require(len(markers)==1,'ambiguous revert')
            target=markers[0]; git('merge-base','--is-ancestor',target,commit+'^')
            parents=git('show','-s','--format=%P',target).split()
            excluded={target}
            if len(parents)>1:
                mainline=re.findall(r'^changes made to ([0-9a-f]{40})\.$',body,re.M)
                require(len(mainline)==1 and mainline[0] in parents,'ambiguous merge revert')
                excluded.update(git('rev-list',mainline[0]+'..'+target).splitlines())
            active.difference_update(excluded)
    for n in sorted(pulls):
        pr,refs=relationship(repo,'pullRequest',n)
        if pr['merged'] is not True or pr['baseRefName']!='main' or pr['mergeCommit']['oid'] not in active: continue
        require(in_milestone(pr) and n in milestone_prs,'merged PR outside release milestone')
        merges[n]=pr['mergeCommit']['oid']
        linked.update(closing_references(pr['body'],repo))
        for ref in refs:
            require(ref['repository']['nameWithOwner'].lower()==repo.lower(),'linked issue outside repository');linked.add(positive(ref['number']))
    require(sha in merges.values() and linked <= issues,'missing release merge or linked issue outside milestone')
    resolved, other = [], []
    for n in sorted(issues):
        issue,events=relationship(repo,'issue',n)
        require(in_milestone(issue) and issue['state']=='CLOSED' and events,'open issue or incomplete closure metadata')
        when=lambda s: datetime.fromisoformat(s.replace('Z','+00:00'))
        last=events[-1]; require(abs((when(last['createdAt'])-when(issue['closedAt'])).total_seconds())<=1,'stale closure event')
        closer=last['closer']; entry=f'- [#{n}]({url}/issues/{n}) — {markdown(issue["title"])}'
        if issue['stateReason']=='NOT_PLANNED': other.append(entry+' (not planned)'); continue
        require(issue['stateReason'] == 'COMPLETED', 'unknown issue closure reason')
        if closer is None: other.append(entry+' (manually closed; no closing PR or commit)'); continue
        closer_repo = closer['repository']['nameWithOwner']
        require(isinstance(closer_repo,str) and closer_repo, 'missing closer repository')
        if closer['__typename']=='Commit': oid=closer['oid']
        else:
            require(closer['__typename']=='PullRequest' and closer['merged'] is True,'invalid closing PR')
            oid=closer['mergeCommit']['oid']
            if closer_repo.lower()==repo.lower() and oid in active:
                require(merges.get(closer['number'])==oid,'unverified closing PR')
        require(re.fullmatch('[0-9a-f]{40}',oid),'missing closing commit')
        if closer_repo.lower() != repo.lower():
            other.append(entry+' (closed from another repository)')
        elif oid in active:
            resolved.append(entry+f' ([closing commit]({url}/commit/{oid}))')
        elif oid in commits:
            other.append(entry+' (closing change reverted in this release range)')
        else:
            other.append(entry+' (closing change outside this release range)')
    return mid, merges, resolved, other
