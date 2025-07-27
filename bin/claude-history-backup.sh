#!/bin/bash

# Claude Code History Backup Script
# バックアップスクリプト：~/.claude/projects/ から timestamp 基準で日次データを抽出

# 基本設定
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKUP_DIR="$PROJECT_ROOT/backup"
CLAUDE_PROJECTS_DIR="$HOME/.claude/projects"
CLEANUP_DAYS=30

# 日付を取得（引数で指定可能）
DATE=${1:-$(date +"%Y-%m-%d")}
BACKUP_FILE="$BACKUP_DIR/claude-history-$DATE.json"

# 必要なディレクトリを作成
mkdir -p "$BACKUP_DIR"

# jqがインストールされているかチェック
if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed. Please install jq to use this script."
    echo "Install with: brew install jq"
    exit 1
fi

# projects/ ディレクトリが存在するかチェック
if [ ! -d "$CLAUDE_PROJECTS_DIR" ]; then
    echo "Error: $CLAUDE_PROJECTS_DIR not found"
    echo "Please run Claude Code at least once to generate project files"
    exit 1
fi

echo "🔍 Extracting logs for $DATE from Claude projects..."

# 結果を格納するJSONを構築
cat > "$BACKUP_FILE" << EOF
{
  "date": "$DATE",
  "generated_at": "$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")",
  "extraction_method": "timestamp_based",
  "projects": {},
  "summary": {
    "total_projects": 0,
    "total_interactions": 0
  }
}
EOF

PROJECT_COUNT=0
TOTAL_INTERACTIONS=0

# プロジェクトデータを収集
for project_dir in "$CLAUDE_PROJECTS_DIR"/*; do
    if [ -d "$project_dir" ]; then
        PROJECT_NAME=$(basename "$project_dir")
        PROJECT_PATH=$(echo "$PROJECT_NAME" | sed 's/-/\//g')
        
        echo "📁 Processing project: $PROJECT_PATH"
        
        # プロジェクトの一時ファイル
        PROJECT_TEMP=$(mktemp)
        echo '{"sessions": {}, "session_count": 0, "total_entries": 0}' > "$PROJECT_TEMP"
        
        SESSION_COUNT=0
        PROJECT_ENTRIES=0
        
        # プロジェクト内のJSONLファイルを処理
        for jsonl_file in "$project_dir"/*.jsonl; do
            if [ -f "$jsonl_file" ]; then
                SESSION_ID=$(basename "$jsonl_file" .jsonl)
                
                # 指定日のエントリを抽出
                DAILY_ENTRIES=$(grep "$DATE" "$jsonl_file" | jq -s '.')
                ENTRY_COUNT=$(echo "$DAILY_ENTRIES" | jq length)
                
                if [ "$ENTRY_COUNT" -gt 0 ]; then
                    echo "    Session $SESSION_ID: $ENTRY_COUNT entries"
                    
                    # セッション情報を追加
                    LAST_TIMESTAMP=$(echo "$DAILY_ENTRIES" | jq -r '.[-1].timestamp // "unknown"')
                    
                    # 大きなデータを一時ファイルに保存
                    echo "$DAILY_ENTRIES" > "$PROJECT_TEMP.entries"
                    jq --arg session_id "$SESSION_ID" \
                       --slurpfile entries "$PROJECT_TEMP.entries" \
                       --argjson count "$ENTRY_COUNT" \
                       --arg timestamp "$LAST_TIMESTAMP" \
                       '.sessions[$session_id] = {
                         "entries": $entries[0],
                         "entry_count": $count,
                         "last_timestamp": $timestamp
                       }' "$PROJECT_TEMP" > "$PROJECT_TEMP.new"
                    rm "$PROJECT_TEMP.entries"
                    
                    mv "$PROJECT_TEMP.new" "$PROJECT_TEMP"
                    
                    SESSION_COUNT=$((SESSION_COUNT + 1))
                    PROJECT_ENTRIES=$((PROJECT_ENTRIES + ENTRY_COUNT))
                fi
            fi
        done
        
        # プロジェクトに活動があった場合
        if [ $SESSION_COUNT -gt 0 ]; then
            # プロジェクト情報を更新
            jq --argjson session_count "$SESSION_COUNT" \
               --argjson total_entries "$PROJECT_ENTRIES" \
               '.session_count = $session_count | .total_entries = $total_entries' \
               "$PROJECT_TEMP" > "$PROJECT_TEMP.new"
            mv "$PROJECT_TEMP.new" "$PROJECT_TEMP"
            
            # メインファイルに追加
            jq --arg project_path "$PROJECT_PATH" \
               --slurpfile project_data "$PROJECT_TEMP" \
               '.projects[$project_path] = $project_data[0]' \
               "$BACKUP_FILE" > "$BACKUP_FILE.new"
            mv "$BACKUP_FILE.new" "$BACKUP_FILE"
            
            PROJECT_COUNT=$((PROJECT_COUNT + 1))
            TOTAL_INTERACTIONS=$((TOTAL_INTERACTIONS + PROJECT_ENTRIES))
            echo "  ✅ Found $SESSION_COUNT sessions with $PROJECT_ENTRIES entries"
        else
            echo "  ⏭️  No activity for this date"
        fi
        
        rm -f "$PROJECT_TEMP" "$PROJECT_TEMP.new" "$PROJECT_TEMP.entries"
    fi
done

# サマリーを更新
jq --argjson total_projects "$PROJECT_COUNT" \
   --argjson total_interactions "$TOTAL_INTERACTIONS" \
   '.summary.total_projects = $total_projects | .summary.total_interactions = $total_interactions' \
   "$BACKUP_FILE" > "$BACKUP_FILE.new"
mv "$BACKUP_FILE.new" "$BACKUP_FILE"

echo ""
echo "✅ Backup completed successfully!"
echo "📊 Statistics:"
echo "  - Date: $DATE"
echo "  - Active projects: $PROJECT_COUNT"
echo "  - Total interactions: $TOTAL_INTERACTIONS"
echo "  - Output file: $BACKUP_FILE"
echo "  - File size: $(du -h "$BACKUP_FILE" | cut -f1)"

# 古いバックアップファイルを削除
echo ""
echo "🧹 Cleaning up old backups..."
find "$BACKUP_DIR" -name "claude-history-*.json" -type f -mtime +${CLEANUP_DAYS} -delete
echo "✅ Cleanup completed"