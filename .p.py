import io
def edit(p, pairs):
    s = io.open(p, encoding='utf-8').read()
    for a, b in pairs:
        assert s.count(a) == 1, (p, a[:50])
        s = s.replace(a, b, 1)
    io.open(p, 'w', encoding='utf-8', newline='\n').write(s)

edit('common/lib.sh', [
(r'''-E BENCH_TRACE="${BENCH_TRACE:-0}" -E BENCH_LOG="$logf" -E BENCH_UNIT="$unit" \''',
 r'''-E BENCH_TRACE="${BENCH_TRACE:-0}" -E BENCH_LOG="$logf" -E BENCH_UNIT="$unit" -E SUDO_USER="${SUDO_USER:-}" \'''),
(r'''pkg_temp_c() {''',
 r'''# give_back — the harness runs as root; hand everything it wrote in the repo
# back to the invoking user, so git (run as that user) can move and pull it.
give_back() {
  [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]] || return 0
  chown -R "$SUDO_USER:" "$LAPTOP_ROOT" 2>/dev/null || warn "could not chown $LAPTOP_ROOT to $SUDO_USER"
}

pkg_temp_c() {'''),
])
for p in ('run_workload.sh', 'pilot.sh'):
    edit(p, [('  (( QUIESCED )) && quiesce_restore\n', '  (( QUIESCED )) && quiesce_restore\n  give_back\n')])
edit('revert.sh', [('quiesce_restore   #', 'give_back\nquiesce_restore   #')])
print('ok')
