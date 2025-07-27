#!/bin/bash

# Claude Code Daily Report Generator
# 手動実行用のシンプルな日報生成ツール

# 基本設定
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKUP_DIR="$PROJECT_ROOT/backup"
TEMPLATES_DIR="$PROJECT_ROOT/templates"
REPORTS_DIR="$PROJECT_ROOT/reports"

# 引数の解析
DATE=${1:-$(date +"%Y-%m-%d")}
TEMPLATE=${2:-"simple"}
BACKUP_FILE="$BACKUP_DIR/claude-history-$DATE.json"
REPORT_FILE="$REPORTS_DIR/daily-report-$DATE.md"
TEMPLATE_FILE="$TEMPLATES_DIR/$TEMPLATE.md"

# 必要なディレクトリを作成
mkdir -p "$REPORTS_DIR"

# バックアップファイルが存在するかチェック
if [ ! -f "$BACKUP_FILE" ]; then
    echo "Error: Backup file not found: $BACKUP_FILE"
    echo "Please run claude-history-backup.sh first:"
    echo "  ./bin/claude-history-backup.sh $DATE"
    exit 1
fi

# テンプレートファイルが存在するかチェック
if [ ! -f "$TEMPLATE_FILE" ]; then
    echo "Error: Template file not found: $TEMPLATE_FILE"
    echo "Available templates:"
    ls -1 "$TEMPLATES_DIR"/*.md 2>/dev/null | sed 's/.*\///; s/\.md$//' | sed 's/^/  - /'
    exit 1
fi

# jqがインストールされているかチェック
if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed. Please install jq to use this script."
    echo "Install with: brew install jq"
    exit 1
fi

echo "📝 Generating daily report for $DATE..."

# 既存の日報ファイルがあるかチェック
if [ -f "$REPORT_FILE" ]; then
    echo "⚠️  Existing report found: $REPORT_FILE"
    echo "   It will be overwritten."
fi

# バックアップファイルから基本情報を取得
TOTAL_PROJECTS=$(jq -r '.summary.total_projects' "$BACKUP_FILE")
TOTAL_INTERACTIONS=$(jq -r '.summary.total_interactions' "$BACKUP_FILE")
GENERATED_AT=$(jq -r '.generated_at' "$BACKUP_FILE")
AVG_INTERACTIONS=$((TOTAL_INTERACTIONS / (TOTAL_PROJECTS > 0 ? TOTAL_PROJECTS : 1)))

# Claude Codeコマンドを動的に検出（簡略化版）
find_claude_command() {
    # 基本的なコマンド検索
    local claude_path=$(command -v claude 2>/dev/null)
    if [ -n "$claude_path" ] && [ -f "$claude_path" ] && [ -x "$claude_path" ]; then
        echo "$claude_path"
        return 0
    fi
    
    # whichコマンドでも試す
    claude_path=$(which claude 2>/dev/null)
    if [ -n "$claude_path" ] && [ -f "$claude_path" ] && [ -x "$claude_path" ]; then
        echo "$claude_path"
        return 0
    fi
    
    # nvmの現在のNode.jsバージョンから検出
    if command -v node >/dev/null 2>&1; then
        local node_path=$(dirname "$(which node)")
        claude_path="$node_path/claude"
        if [ -f "$claude_path" ] && [ -x "$claude_path" ]; then
            echo "$claude_path"
            return 0
        fi
    fi
    
    # 一般的なシステムパス
    for path in "/usr/local/bin/claude" "/opt/homebrew/bin/claude" "$HOME/.local/bin/claude"; do
        if [ -f "$path" ] && [ -x "$path" ]; then
            echo "$path"
            return 0
        fi
    done
    
    return 1
}

# 日報分析を実行（共通処理）
analyze_daily_activities() {
    local all_messages=""
    
    # 各プロジェクトのメッセージを収集
    while IFS='|' read -r project_path entries; do
        # プロジェクト名を適切に抽出
        local project_name=""
        if [[ "$project_path" == *"/claude/daily/reporter"* ]] || [[ "$project_path" == *"claude-daily-reporter"* ]]; then
            project_name="claude-daily-reporter"
        elif [[ "$project_path" == *"/order/print"* ]]; then
            project_name="order-print"
        else
            # その他のプロジェクトの場合は最後の2つのディレクトリ名を結合
            local dir1=$(basename "$(dirname "$project_path")")
            local dir2=$(basename "$project_path")
            project_name="${dir1}-${dir2}"
        fi
        
        # プロジェクトのメッセージを取得（ユーザーとアシスタントの両方）
        local user_messages=$(jq -r --arg proj "$project_path" '
            .projects[$proj].sessions | 
            to_entries[]? | 
            .value.entries[]? | 
            select(.type == "user" and (.message.content | type) == "string") | 
            .message.content
        ' "$BACKUP_FILE" 2>/dev/null | 
            grep -v "^$" | 
            grep -v "^# 日報分析コマンド$" | 
            grep -E ".{10,}" | 
            head -200)
            
        # アシスタントの作業メッセージも取得（ファイル操作など）
        local assistant_messages=$(jq -r --arg proj "$project_path" '
            .projects[$proj].sessions | 
            to_entries[]? | 
            .value.entries[]? | 
            select(.type == "assistant") | 
            .message.content | 
            if type == "array" then 
                .[] | 
                if .type == "text" then .text 
                elif type == "string" then .
                else empty end
            elif type == "string" then . 
            else empty end
        ' "$BACKUP_FILE" 2>/dev/null | 
            grep -E "(作成しました|更新しました|削除しました|追加しました|変更しました|修正しました|実装しました|完了しました|ファイル|テンプレート|スクリプト|コマンド)" | 
            grep -v "^#" | 
            head -200)
            
        # ツール使用結果からも作業内容を抽出
        local tool_results=$(jq -r --arg proj "$project_path" '
            .projects[$proj].sessions | 
            to_entries[]? | 
            .value.entries[]? | 
            select(.type == "user") | 
            .message.content | 
            if type == "array" then 
                .[] | 
                select(.type == "tool_result") | 
                .content | 
                if type == "string" then . else empty end
            else empty end
        ' "$BACKUP_FILE" 2>/dev/null | 
            grep -E "(File created|file.*updated|Deleted|Renamed|has been (created|updated|deleted)|successfully)" | 
            head -100)
            
        # メッセージを結合
        local project_messages=""
        if [ -n "$user_messages" ]; then
            project_messages="[USER MESSAGES]\n$user_messages"
        fi
        if [ -n "$assistant_messages" ]; then
            project_messages="$project_messages\n\n[ASSISTANT WORK]\n$assistant_messages"
        fi
        if [ -n "$tool_results" ]; then
            project_messages="$project_messages\n\n[TOOL RESULTS]\n$tool_results"
        fi
        
        # プロジェクト名を付けてメッセージを追加
        if [ -n "$project_messages" ]; then
            all_messages="$all_messages\n[PROJECT:$project_name]\n$project_messages"
        fi
    done < <(jq -r '.projects | to_entries[] | "\(.key)|\(.value.total_entries)"' "$BACKUP_FILE")
    
    
    # フォールバック：キーワード検索
    if [ -n "$all_messages" ]; then
        local work_items=$(echo "$all_messages" | grep -iE "(実装|作成|追加|修正|改善|対応|開発|テスト|レビュー|デバッグ|リファクタリング|更新|削除|変更|設定|構築|導入|解決|調査|分析|確認|検証)" | head -10)
        if [ -n "$work_items" ]; then
            echo "$work_items" | while read -r line; do
                echo "WORK:- ${line:0:80}$([ ${#line} -gt 80 ] && echo "...")"
            done
        else
            echo "WORK:- 作業内容を取得できませんでした"
        fi
    else
        echo "WORK:- メッセージが見つかりませんでした"
    fi
}



# 分析結果から各項目を抽出（プロジェクト別にグループ化）
extract_work_items() {
    if [ "$TOTAL_PROJECTS" -eq 0 ]; then
        echo "### 作業なし"
        echo "- この日は Claude Code での作業記録がありません"
        return
    fi
    
    # 各プロジェクトを処理
    while IFS='|' read -r project_path entries; do
        # プロジェクト名を適切に抽出
        local project_name=""
        if [[ "$project_path" == *"/claude/daily/reporter"* ]] || [[ "$project_path" == *"claude-daily-reporter"* ]]; then
            project_name="claude-daily-reporter"
        elif [[ "$project_path" == *"/order/print"* ]]; then
            project_name="order-print"
        else
            # その他のプロジェクトの場合は最後の2つのディレクトリ名を結合
            local dir1=$(basename "$(dirname "$project_path")")
            local dir2=$(basename "$project_path")
            project_name="${dir1}-${dir2}"
        fi
        
        echo "### $project_name"
        
        # プロジェクトのメッセージを取得
        local project_messages=$(jq -r --arg proj "$project_path" '
            .projects[$proj].sessions | 
            to_entries[]? | 
            .value.entries[]? | 
            select(.type == "user" and (.message.content | type) == "string") | 
            .message.content
        ' "$BACKUP_FILE" 2>/dev/null | 
            grep -v "^$" | 
            grep -v "^# 日報分析コマンド$" | 
            grep -E ".{10,}" | 
            head -200)
            
        # アシスタントの作業メッセージも取得
        local assistant_messages=$(jq -r --arg proj "$project_path" '
            .projects[$proj].sessions | 
            to_entries[]? | 
            .value.entries[]? | 
            select(.type == "assistant") | 
            .message.content | 
            if type == "array" then 
                .[] | 
                if .type == "text" then .text 
                elif type == "string" then .
                else empty end
            elif type == "string" then . 
            else empty end
        ' "$BACKUP_FILE" 2>/dev/null | 
            grep -E "(作成しました|更新しました|削除しました|追加しました|変更しました|修正しました|実装しました|完了しました|ファイル|テンプレート|スクリプト|コマンド)" | 
            grep -v "^#" | 
            head -200)
        
        # プロジェクト別の作業内容を分析
        local all_project_messages="$project_messages"$'\n'"$assistant_messages"
        local work_items=$(analyze_project_activities "$project_path" "$all_project_messages")
        
        if [ -n "$work_items" ]; then
            echo "$work_items"
        else
            echo "- 作業内容を取得できませんでした"
        fi
        echo ""
    done < <(jq -r '.projects | to_entries[] | "\(.key)|\(.value.total_entries)"' "$BACKUP_FILE")
}

extract_learned_things() {
    echo "$DAILY_ANALYSIS" | grep "^LEARNED:" | sed 's/^LEARNED://' | head -3
}

extract_stuck_things() {
    echo "$DAILY_ANALYSIS" | grep "^STUCK:" | sed 's/^STUCK://' | head -3
}

extract_troubled_things() {
    echo "$DAILY_ANALYSIS" | grep "^TROUBLED:" | sed 's/^TROUBLED://' | head -3
}

# 分析ステータスを取得
get_analysis_status() {
    # claudeコマンドのパスを動的に検出
    claude_cmd=$(find_claude_command)
    
    if [ -n "$claude_cmd" ]; then
        echo "✅ **Claude分析済み** - AI分析によって作業内容を自動解析しました"
        echo "  - 使用したコマンド: $claude_cmd"
    else
        echo "⚠️ **キーワード検索のみ** - Claude分析機能が利用できませんでした"
        echo "  - Claude Codeコマンドが見つかりません"
    fi
}

# テンプレートエンジン関数
render_template() {
    local template_content="$1"
    local output="$template_content"
    
    # 基本変数を置換
    output=$(echo "$output" | sed "s/{{DATE}}/$DATE/g")
    output=$(echo "$output" | sed "s/{{GENERATED_TIME}}/$(date +"%Y-%m-%d %H:%M:%S")/g")
    output=$(echo "$output" | sed "s/{{EXTRACTED_TIME}}/$GENERATED_AT/g")
    output=$(echo "$output" | sed "s/{{TOTAL_PROJECTS}}/$TOTAL_PROJECTS/g")
    output=$(echo "$output" | sed "s/{{TOTAL_INTERACTIONS}}/$TOTAL_INTERACTIONS/g")
    output=$(echo "$output" | sed "s/{{AVG_INTERACTIONS}}/$AVG_INTERACTIONS/g")
    
    echo "$output"
}

# プロジェクト別データを生成
generate_projects_data() {
    local template_section="$1"
    local projects_output=""
    
    # プロジェクトが存在しない場合
    if [ "$TOTAL_PROJECTS" -eq 0 ]; then
        echo "📭 **活動なし**: この日は Claude Code での作業記録がありません。"
        return
    fi
    
    # 各プロジェクトを処理
    jq -r '.projects | to_entries[] | .key' "$BACKUP_FILE" | while read -r project; do
        local project_section="$template_section"
        local session_count=$(jq -r --arg project "$project" '.projects[$project].session_count' "$BACKUP_FILE")
        local total_entries=$(jq -r --arg project "$project" '.projects[$project].total_entries' "$BACKUP_FILE")
        
        # プロジェクト変数を置換
        project_section=$(echo "$project_section" | awk -v proj="$project" '{gsub(/\{\{PROJECT_PATH\}\}/, proj); print}')
        project_section=$(echo "$project_section" | awk -v count="$session_count" '{gsub(/\{\{SESSION_COUNT\}\}/, count); print}')
        project_section=$(echo "$project_section" | awk -v total="$total_entries" '{gsub(/\{\{TOTAL_ENTRIES\}\}/, total); print}')
        
        # セッション詳細を処理
        local sessions_output=""
        jq -r --arg project "$project" '.projects[$project].sessions | to_entries[]? | .key' "$BACKUP_FILE" 2>/dev/null | while read -r session_id; do
            local entry_count=$(jq -r --arg project "$project" --arg session "$session_id" '.projects[$project].sessions[$session].entry_count' "$BACKUP_FILE")
            local last_timestamp=$(jq -r --arg project "$project" --arg session "$session_id" '.projects[$project].sessions[$session].last_timestamp' "$BACKUP_FILE")
            
            # タイムスタンプを読みやすい形式に変換
            local formatted_time="時刻不明"
            if [ "$last_timestamp" != "unknown" ] && [ "$last_timestamp" != "null" ]; then
                formatted_time=$(date -d "$last_timestamp" +"%H:%M:%S" 2>/dev/null || echo "時刻不明")
            fi
            
            local session_id_short="${session_id:0:8}"
            
            # セッション変数を置換
            local session_section=$(echo "$project_section" | sed -n '|{{#SESSIONS}}|,|{{/SESSIONS}}|p')
            session_section=$(echo "$session_section" | sed '1d; $d')  # 開始・終了行を削除
            session_section=$(echo "$session_section" | sed "s/{{SESSION_ID_SHORT}}/$session_id_short/g")
            session_section=$(echo "$session_section" | sed "s/{{ENTRY_COUNT}}/$entry_count/g")
            session_section=$(echo "$session_section" | sed "s/{{LAST_TIME}}/$formatted_time/g")
            
            # 主要な内容を抽出
            local main_contents=""
            jq -r --arg project "$project" --arg session "$session_id" '
                .projects[$project].sessions[$session].entries[] |
                select(.type == "user" and .message.content != null) |
                .message.content |
                if type == "string" then . else (.[0].text // "内容を取得できませんでした") end
            ' "$BACKUP_FILE" | head -3 | while IFS= read -r content; do
                # 内容を80文字に制限
                if [ ${#content} -gt 80 ]; then
                    content="${content:0:80}..."
                fi
                main_contents="$main_contents  - $content\\n"
            done
            
            # 主要内容を置換
            session_section=$(echo "$session_section" | sed "|{{#MAIN_CONTENTS}}|,|{{/MAIN_CONTENTS}}|c\\
$main_contents")
            
            sessions_output="$sessions_output$session_section\\n"
        done
        
        # セッション部分を置換
        project_section=$(echo "$project_section" | sed "|{{#SESSIONS}}|,|{{/SESSIONS}}|c\\
$sessions_output")
        
        projects_output="$projects_output$project_section\\n"
    done
    
    echo -e "$projects_output"
}

# トッププロジェクトを生成

# プロジェクト別の活動分析
analyze_project_activities() {
    local project="$1"
    local messages="$2"
    
    # claudeコマンドのパスを動的に検出
    claude_cmd=$(find_claude_command)
    
    if [ -n "$claude_cmd" ]; then
        # Claude分析でプロジェクト別の作業内容を抽出
        local temp_prompt=$(mktemp)
        cat > "$temp_prompt" << EOF
以下は「$(basename "$project")」プロジェクトでの作業内容です。この内容から具体的に行った作業を3-5項目で箇条書きにまとめてください。

要件：
- 「- 」で始まる箇条書き形式
- 各項目は80文字以内
- 具体的な作業内容を要約
- ユーザーの指示内容ではなく、実際に行った作業を記載
- 技術的な内容は専門用語を使用

作業内容：
$messages
EOF
        
        local result=$("$claude_cmd" < "$temp_prompt" 2>/dev/null)
        rm -f "$temp_prompt"
        
        if [ -n "$result" ]; then
            echo "$result" | grep "^- " | head -5
        else
            # フォールバック：キーワード検索
            echo "$messages" | grep -iE "(実装|作成|追加|修正|改善|対応|開発|テスト|レビュー|デバッグ)" | head -3 | while read -r line; do
                echo "- ${line:0:80}$([ ${#line} -gt 80 ] && echo "...")"
            done
        fi
    else
        # フォールバック：キーワード検索
        echo "$messages" | grep -iE "(実装|作成|追加|修正|改善|対応|開発|テスト|レビュー|デバッグ)" | head -3 | while read -r line; do
            echo "- ${line:0:80}$([ ${#line} -gt 80 ] && echo "...")"
        done
    fi
}

generate_top_projects() {
    jq -r '.projects | to_entries | sort_by(.value.total_entries) | reverse | .[0:5][] | "\(.key)|\(.value.total_entries)"' "$BACKUP_FILE" | \
    while IFS='|' read -r project_name entry_count; do
        echo "- **$project_name**: $entry_count 件"
    done
}

# 分析を実行
echo "🔍 Analyzing daily activities..."
DAILY_ANALYSIS=$(analyze_daily_activities)
ANALYSIS_STATUS=$(get_analysis_status)

# テンプレートを読み込み
template_content=$(cat "$TEMPLATE_FILE")

# 基本変数を置換
output=$(render_template "$template_content")

# 各セクションを処理して一時ファイルに保存（Claude分析結果を使用）
work_items=$(extract_work_items)
learned_things=$(extract_learned_things)
stuck_things=$(extract_stuck_things)
troubled_things=$(extract_troubled_things)

TEMP_WORK=$(mktemp)
TEMP_LEARNED=$(mktemp)
TEMP_STUCK=$(mktemp)
TEMP_TROUBLED=$(mktemp)
TEMP_ANALYSIS=$(mktemp)

echo "$work_items" > "$TEMP_WORK"
echo "$learned_things" > "$TEMP_LEARNED"
echo "$stuck_things" > "$TEMP_STUCK"
echo "$troubled_things" > "$TEMP_TROUBLED"
echo "$ANALYSIS_STATUS" > "$TEMP_ANALYSIS"

# 一行ずつ処理
TEMP_OUTPUT=$(mktemp)
in_section=""
while IFS= read -r line; do
    case "$line" in
        *"{{#ANALYSIS_STATUS}}"*)
            in_section="analysis"
            cat "$TEMP_ANALYSIS" >> "$TEMP_OUTPUT"
            ;;
        *"{{/ANALYSIS_STATUS}}"*)
            in_section=""
            ;;
        *"{{#WORK_ITEMS}}"*)
            in_section="work"
            cat "$TEMP_WORK" >> "$TEMP_OUTPUT"
            ;;
        *"{{/WORK_ITEMS}}"*)
            in_section=""
            ;;
        *"{{#LEARNED_THINGS}}"*)
            in_section="learned"
            cat "$TEMP_LEARNED" >> "$TEMP_OUTPUT"
            ;;
        *"{{/LEARNED_THINGS}}"*)
            in_section=""
            ;;
        *"{{#STUCK_THINGS}}"*)
            in_section="stuck"
            cat "$TEMP_STUCK" >> "$TEMP_OUTPUT"
            ;;
        *"{{/STUCK_THINGS}}"*)
            in_section=""
            ;;
        *"{{#TROUBLED_THINGS}}"*)
            in_section="troubled"
            cat "$TEMP_TROUBLED" >> "$TEMP_OUTPUT"
            ;;
        *"{{/TROUBLED_THINGS}}"*)
            in_section=""
            ;;
        *)
            if [ -z "$in_section" ]; then
                echo "$line" >> "$TEMP_OUTPUT"
            fi
            ;;
    esac
done <<< "$output"

output=$(cat "$TEMP_OUTPUT")

# 一時ファイルを削除
rm -f "$TEMP_WORK" "$TEMP_LEARNED" "$TEMP_STUCK" "$TEMP_TROUBLED" "$TEMP_ANALYSIS" "$TEMP_OUTPUT"

# プロジェクト部分とトッププロジェクトを処理
TEMP_PROJECTS=$(mktemp)
TEMP_TOP_PROJECTS=$(mktemp)

# 作業内容を生成（簡略化版）
TEMP_WORK_ITEMS=$(mktemp)
echo "$work_items" > "$TEMP_WORK_ITEMS"

# トッププロジェクト
generate_top_projects > "$TEMP_TOP_PROJECTS"

# テンプレート処理
TEMP_OUTPUT2=$(mktemp)
in_section=""
while IFS= read -r line; do
    case "$line" in
        *"{{#WORK_ITEMS}}"*)
            in_section="work_items"
            cat "$TEMP_WORK_ITEMS" >> "$TEMP_OUTPUT2"
            ;;
        *"{{/WORK_ITEMS}}"*)
            in_section=""
            ;;
        *"{{#TOP_PROJECTS}}"*)
            in_section="top_projects"
            cat "$TEMP_TOP_PROJECTS" >> "$TEMP_OUTPUT2"
            ;;
        *"{{/TOP_PROJECTS}}"*)
            in_section=""
            ;;
        *)
            if [ -z "$in_section" ]; then
                echo "$line" >> "$TEMP_OUTPUT2"
            fi
            ;;
    esac
done <<< "$output"

output=$(cat "$TEMP_OUTPUT2")
rm -f "$TEMP_WORK_ITEMS" "$TEMP_TOP_PROJECTS" "$TEMP_OUTPUT2"

# 結果を出力
echo "$output" > "$REPORT_FILE"

echo ""
echo "✅ Daily report generated successfully!"
echo "📊 Statistics:"
echo "  - Total projects: $TOTAL_PROJECTS"
echo "  - Total interactions: $TOTAL_INTERACTIONS"
echo "  - Output file: $REPORT_FILE"
echo "  - File size: $(du -h "$REPORT_FILE" | cut -f1)"