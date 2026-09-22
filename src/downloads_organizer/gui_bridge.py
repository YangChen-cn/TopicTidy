"""One-request JSON transport for the native app; business logic stays in services."""
from __future__ import annotations

import json
import sys
from pathlib import Path

from .config import Settings
from .db import Database, loads
from .locking import app_lock
from .operations import apply_plan, edit_plan, plan_rows, preview_moves, undo_batch
from .preferences import PreferenceStore
from .scanner import scan
from .scheduler import LaunchAgentScheduler
from .workflow import create_proposal


def snapshot(db, settings, plan_id=None):
    if plan_id is None:
        row = db.conn.execute("SELECT id,status FROM plans ORDER BY id DESC LIMIT 1").fetchone()
        plan_id = row[0] if row and row['status'] == 'draft' else None
    members = []
    if plan_id is not None:
        for row in plan_rows(db, plan_id):
            members.append({
                'id': row['id'], 'name': row['name'], 'path': row['path'],
                'topic': row['group_name'], 'topic_key': row['topic_key'],
                'confidence': row['confidence'], 'excluded': bool(row['excluded']),
                'applied': bool(row['applied']),
                'evidence': loads(row['evidence'], []), 'conflicts': loads(row['conflicts'], []),
            })
    history = [dict(row) for row in db.conn.execute(
        "SELECT id,kind,status,created_at FROM operation_batches ORDER BY id DESC LIMIT 40"
    )]
    return {'plan_id': plan_id, 'members': members, 'history': history,
            'preferences': PreferenceStore(db, settings).get().as_dict(),
            'schedule': LaunchAgentScheduler(settings).status().as_dict(),
            'downloads': str(settings.downloads)}


def dispatch(request):
    base = Settings.load()
    with app_lock(base.data_dir):
        db = Database(base.database)
        try:
            db.recover_interrupted()
            store = PreferenceStore(db, base)
            settings = store.resolved_settings()
            action = request.get('action', 'status')
            plan_id = request.get('plan_id')
            message = None
            moves = []
            if action in {'edit', 'preview', 'apply'}:
                plan = db.conn.execute('SELECT status FROM plans WHERE id=?', (plan_id,)).fetchone()
                if not plan or plan['status'] != 'draft':
                    raise ValueError('方案已执行或不存在，请重新扫描生成建议')
            if action == 'scan':
                stats = scan(db, settings, wait_for_stability=True)
                result = create_proposal(db, settings, use_semantic=request.get('semantic', True))
                plan_id = result.plan_id
                message = f"扫描完成，更新 {stats['scanned']} 个文件，提取错误 {stats['errors']} 个"
                warnings = [result.semantic_error, *result.translation_warnings]
                message += ''.join('；' + text for text in warnings if text)
            elif action == 'edit':
                message = edit_plan(db, plan_id, request['command'], request['args'], settings.organized_dir)
            elif action == 'preview':
                topic_key = request.get('topic_key')
                member_ids = ({int(row['id']) for row in plan_rows(db, plan_id)
                               if row['topic_key'] == topic_key} if topic_key else None)
                moves = [{k: str(v) if isinstance(v, Path) else v for k, v in move.items()}
                         for move in preview_moves(db, settings, plan_id, member_ids=member_ids)]
            elif action == 'apply':
                if request.get('confirmed') is not True:
                    raise ValueError('必须先审阅移动清单并确认')
                requested_ids = {int(move['member_id']) for move in request.get('moves', [])}
                if not requested_ids:
                    raise ValueError('移动清单已变化，请重新预览后确认')
                pending = [row for row in plan_rows(db, plan_id)
                           if not row['excluded'] and not row['applied'] and row['group_name']]
                all_pending_ids = {int(row['id']) for row in pending}
                selected_topics = {row['topic_key'] for row in pending if int(row['id']) in requested_ids}
                selected_topic_ids = ({int(row['id']) for row in pending
                                       if row['topic_key'] in selected_topics}
                                      if len(selected_topics) == 1 else set())
                if frozenset(requested_ids) not in {frozenset(all_pending_ids), frozenset(selected_topic_ids)}:
                    raise ValueError('只能确认完整主题或全部待整理主题')
                current = [{k: str(v) if isinstance(v, Path) else v for k, v in move.items()}
                           for move in preview_moves(db, settings, plan_id, member_ids=requested_ids)]
                if request.get('moves') != current:
                    raise ValueError('移动清单已变化，请重新预览后确认')
                batch, results = apply_plan(db, settings, plan_id, member_ids=requested_ids)
                message = f"批次 {batch}：已移动 {sum(r['status'] == 'moved' for r in results)}，跳过 {sum(r['status'] != 'moved' for r in results)}"
                message += ''.join('；' + r['error'] for r in results if r['error'])
                plan = db.conn.execute('SELECT status FROM plans WHERE id=?', (plan_id,)).fetchone()
                if plan['status'] != 'draft':
                    plan_id = None
            elif action == 'undo':
                if request.get('confirmed') is not True:
                    raise ValueError('撤销需要确认')
                batch, results = undo_batch(db, settings, request['batch_id'])
                message = f"撤销批次 {batch}：恢复 {sum(r['status'] == 'undone' for r in results)}，跳过 {sum(r['status'] != 'undone' for r in results)}"
                message += ''.join('；' + r['error'] for r in results if r['error'])
            elif action == 'preferences':
                if 'destination' in request:
                    store.set_destination(Path(request['destination']))
                if 'enabled' in request:
                    store.set_auto_confirm(request['enabled'], request.get('threshold'))
                settings = store.resolved_settings()
                message = '设置已保存'
            elif action == 'schedule':
                scheduler = LaunchAgentScheduler(settings)
                if request['enabled']:
                    scheduler.enable(request['at'])
                else:
                    scheduler.disable()
                message = '每日扫描设置已更新'
            elif action != 'status':
                raise ValueError('未知操作')
            return {'ok': True, 'snapshot': snapshot(db, settings, plan_id), 'message': message, 'moves': moves}
        finally:
            db.close()


def main():
    try:
        response = dispatch(json.load(sys.stdin))
    except Exception as exc:
        response = {'ok': False, 'error': str(exc)}
    print(json.dumps(response, ensure_ascii=False))


if __name__ == '__main__':
    main()
