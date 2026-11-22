"""Bare file-only remotes; exercise reordered deliveries and non-fast-forward push races."""
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().with_name('publish-wiki.sh')


class Mirror(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.env = dict(PATH='/usr/bin:/bin', HOME=tmp.name, GIT_CONFIG_NOSYSTEM='1',
                        GIT_CONFIG_GLOBAL='/dev/null', GIT_ALLOW_PROTOCOL='file', LC_ALL='C',
                        GIT_AUTHOR_NAME='Fixture', GIT_AUTHOR_EMAIL='fixture@example.invalid',
                        GIT_COMMITTER_NAME='Fixture', GIT_COMMITTER_EMAIL='fixture@example.invalid')
        self.main = self.root/'main.git'; self.wiki = self.root/'wiki.git'
        for remote, branch in ((self.main, 'main'), (self.wiki, 'master')):
            self.git(self.root, 'init', '--bare', '-b', branch, remote)
        self.source = self.root/'source'; self.git(self.root,'clone',self.main,self.source)
        (self.source/'wiki').mkdir()
        self.a = self.advance('A')
        initial = self.root/'initial'; self.git(self.root,'clone',self.wiki,initial)
        (initial/'Home.md').write_text('A'); self.git(initial,'add','Home.md')
        self.git(initial,'commit','-m','Publish wiki from '+self.a); self.git(initial,'push','origin','master')

    def git(self, cwd, *args):
        return subprocess.check_output(['git','-C',cwd,*args], env=self.env, text=True, stderr=subprocess.PIPE).strip()

    def advance(self, label, content=None):
        (self.source/'wiki/Home.md').write_text(content or label)
        self.git(self.source,'add','wiki/Home.md'); self.git(self.source,'commit','--allow-empty','-m',label)
        self.git(self.source,'push','origin','main'); return self.git(self.source,'rev-parse','HEAD')

    def runner(self, name, sha):
        source = self.root/(name+'-src'); dest = self.root/(name+'-wiki')
        self.git(self.root,'clone',self.main,source); self.git(source,'checkout','--detach',sha)
        self.git(self.root,'clone',self.wiki,dest)
        return source/'wiki', dest, sha

    def publish(self, runner, ok=True, **env):
        r=subprocess.run([SCRIPT,*runner],cwd=self.root,env={**self.env,**env},capture_output=True,text=True,timeout=15)
        self.assertEqual(r.returncode==0,ok,r.stdout+r.stderr)
        return r

    def tip(self):
        return self.git(self.wiki,'rev-parse','master')

    def test_dropped_middle_push_and_late_older_jobs_never_roll_back(self):
        a=self.runner('A',self.a); b=self.advance('B'); late_b=self.runner('B',b)
        c=self.advance('C'); newest=self.runner('C',c)
        self.publish(newest); tip=self.tip()
        self.assertEqual(self.git(self.wiki,'show','master:Home.md'),'C')
        new_message='Published wiki from '+c
        for runner in (a, late_b, newest):
            result=self.publish(runner); self.assertEqual(self.tip(),tip)
            self.assertIn('no publish needed',result.stdout); self.assertNotIn(new_message,result.stdout)
            self.assertEqual(self.git(self.wiki,'show','-s','--format=%s','master'),'Publish wiki from '+c)

    def test_unchanged_newest_pages_still_advance_source_marker(self):
        b=self.advance('B'); late=self.runner('B',b)
        c=self.advance('C',content='A');self.publish(self.runner('C',c))
        tip=self.tip();self.publish(late);self.assertEqual(self.tip(),tip)
        self.assertEqual(self.git(self.wiki,'show','master:Home.md'),'A')
        self.assertEqual(self.git(self.wiki,'show','-s','--format=%s','master'),'Publish wiki from '+c)

    def test_racing_push_reconciles_older_and_newer_winners(self):
        b=self.advance('B'); old=self.runner('B',b); c=self.advance('C'); new=self.runner('C',c)
        for first,competing in ((old,new),(new,old)):
            with self.subTest(delayed=first[2]):
                if first==new:
                    # Independent unpublished clones and a fresh remote for the reverse order.
                    self.wiki=self.root/'reverse.git';self.git(self.root,'clone','--bare',self.root/'initial',self.wiki)
                    first=self.runner('C2',c);competing=self.runner('B2',b)
                bindir=self.root/('bin-'+first[2]);bindir.mkdir();wrapper=bindir/'git'
                wrapper.write_text('''#!/bin/sh
case " $* " in
    *" push "*)
        if [ ! -e "$ONCE" ]; then
            touch "$ONCE"
            PATH=/usr/bin:/bin "$MIRROR" "$OTHER_SRC" "$OTHER_WIKI" "$OTHER_SHA" || exit 98
        fi ;;
esac
exec /usr/bin/git "$@"
''');wrapper.chmod(0o755)
                once=bindir/'once'
                self.publish(first,PATH=str(bindir)+':/usr/bin:/bin',MIRROR=str(SCRIPT),ONCE=str(once),
                             OTHER_SRC=str(competing[0]),OTHER_WIKI=str(competing[1]),OTHER_SHA=competing[2])
                self.assertTrue(once.exists(),'no competing push was exercised')
                self.assertEqual(self.git(self.wiki,'show','master:Home.md'),'C')
                self.assertEqual(self.git(self.wiki,'show','-s','--format=%s','master'),'Publish wiki from '+c)

    def test_tip_advancing_after_receive_pack_advertises_is_reconciled(self):
        b=self.advance('B'); delayed=self.runner('B',b)
        c=self.advance('C'); competing=self.runner('C',c)
        # A second real push wins *after* the delayed sender negotiated its ref update.
        # The server reports a failed ref lock, not a client-side non-fast-forward.
        hook=delayed[1]/'.git/hooks/pre-push'; hook.write_text('''#!/bin/sh
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR
"$MIRROR" "$OTHER_SRC" "$OTHER_WIKI" "$OTHER_SHA"
''');hook.chmod(0o755)
        self.publish(delayed,MIRROR=str(SCRIPT),OTHER_SRC=str(competing[0]),OTHER_WIKI=str(competing[1]),OTHER_SHA=c)
        self.assertEqual(self.git(self.wiki,'show','master:Home.md'),'C')

    def test_auth_failure_is_not_hidden_even_when_a_newer_mirror_wins(self):
        b=self.advance('B');old=self.runner('B',b);c=self.advance('C');new=self.runner('C',c)
        tools=self.root/'auth';tools.mkdir();wrapper=tools/'git'
        wrapper.write_text('''#!/bin/sh
case " $* " in *" push "*)
    PATH=/usr/bin:/bin "$MIRROR" "$OTHER_SRC" "$OTHER_WIKI" "$OTHER_SHA" || exit 98
    echo 'fatal: Authentication failed (fixture)' >&2; exit 128;;
esac
exec /usr/bin/git "$@"
''');wrapper.chmod(0o755)
        failure=self.publish(old,False,PATH=str(tools)+':/usr/bin:/bin',MIRROR=str(SCRIPT),
                             OTHER_SRC=str(new[0]),OTHER_WIKI=str(new[1]),OTHER_SHA=c)
        self.assertIn('Authentication failed',failure.stderr)
        self.assertEqual(self.git(self.wiki,'show','master:Home.md'),'C')

    def test_remote_rejection_and_read_error_are_not_superseded_success(self):
        b=self.advance('B');runner=self.runner('B',b);tip=self.tip()
        hook=self.wiki/'hooks/pre-receive';hook.write_text('#!/bin/sh\necho "fixture denies write" >&2\nexit 1\n');hook.chmod(0o755)
        self.publish(runner,ok=False);self.assertEqual(self.tip(),tip)
        self.git(runner[1],'remote','set-url','origin',self.root/'missing.git')
        self.publish(runner,ok=False)


if __name__=='__main__': unittest.main()
