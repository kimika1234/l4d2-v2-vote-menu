#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <l4d2_nativevote>
#include <colors>

#define PLUGIN_VERSION "3.1.3"
#define VM_CFG_PATH "configs/vote_manager.cfg"
#define MAX_MENU_ITEMS 1024
#define INTEGRATED_CFG "cfg/vote/v2_integrated.cfg"
#define RELOAD_HOLD_TIME 3.0
#define PANEL_OPTIONS_PER_PAGE 5   // Panel 每页选项数（L4D2 Panel 显示区 ~10 行，保底底部提示键可见）
#define MENU_TIMEOUT 30000         // 菜单 30 秒无操作自动关闭（GetSysTickCount 真实时钟）

// ===== 菜单数据结构（vote_manager.cfg 驱动）=====
enum struct MenuItem
{
	char display[128];    // 选项显示名
	char exec_on[512];    // "exec xxx.cfg"
	bool is_ff;           // 友伤/火伤/反伤/同伤（整合时最后覆盖）
}

enum struct MenuSubCat
{
	char name[64];
	int  cat_index;        // 所属一级分类
	int  first_item_row;   // 选项起始行
	int  item_count;
}

enum struct MenuCat
{
	char name[64];
	int  first_sub;        // 子分类起始
	int  sub_count;
	int  first_item_row;   // 叶子选项起始（无子分类时使用）
	int  item_count;
}

enum MenuLevel
{
	Level_Main,    // 主菜单
	Level_Cat,     // 分类菜单
	Level_Sub      // 子分类菜单
}

ArrayList g_Items;
ArrayList g_SubCats;
ArrayList g_Cats;
bool g_bMenuBuilt;

// 玩家勾选状态（按 g_Items 行索引）
bool g_Selected[MAXPLAYERS + 1][MAX_MENU_ITEMS];

// 菜单状态（Panel 版）
bool g_bMenuOpen[MAXPLAYERS + 1];
bool g_bVoteActive[MAXPLAYERS + 1];  // 投票进行中（暂停菜单超时检测与重画）
MenuLevel g_iMenuLevel[MAXPLAYERS + 1];
int g_iMenuIndex[MAXPLAYERS + 1];   // 当前分类/子分类索引
int g_iMenuPage[MAXPLAYERS + 1];    // 当前页
int g_iMenuOpenTime[MAXPLAYERS + 1]; // 打开时间（GetSysTickCount）
Handle g_hMenuTimer;

// 当前投票发起者（VoteAction_End 的 param1 是 reason，需要自行记录）
int g_iVoteInitiator;

// 长按 R 状态
float g_fReloadHold[MAXPLAYERS + 1];
bool g_bReloadFired[MAXPLAYERS + 1];

// 当前投票数据
ArrayList g_VoteItems;
ArrayList g_VoteFF;
bool g_bVoteNeedRestart;

enum VoteScope
{
	VoteScope_All,     // 全部勾选（主菜单确认）
	VoteScope_Cat,     // 某分类
	VoteScope_SubCat   // 某子分类
}

public Plugin myinfo =
{
	name = "[L4D2] Server Settings V2",
	author = "OrangeJuice",
	description = "!v2 投票菜单（vote_manager.cfg 驱动，Panel方案 + 多选聚合 + 长按R）",
	version = PLUGIN_VERSION,
	url = ""
};

public void OnPluginStart()
{
	RegConsoleCmd("sm_v2", Cmd_V2, "打开服务器设置菜单");
	RegConsoleCmd("sm_sj", Cmd_V2, "打开服务器设置菜单");
	RegConsoleCmd("sm_sz", Cmd_V2, "打开服务器设置菜单");
	RegAdminCmd("sm_v2reload", Cmd_V2Reload, ADMFLAG_RCON, "重新读取 vote_manager.cfg 并重建菜单");
	HookEvent("player_disconnect", Event_PlayerDisconnect);
}

public void OnMapStart()
{
	// 换图自动重读 vote_manager.cfg（改配置无需更新插件）
	if (g_bMenuBuilt)
	{
		BuildMenu();
	}
}

public void OnAllPluginsLoaded()
{
	BuildMenu();
}

public void OnClientDisconnect(int client)
{
	g_fReloadHold[client] = 0.0;
	g_bReloadFired[client] = false;
	g_bMenuOpen[client] = false;
	g_bVoteActive[client] = false;
}

void Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client > 0 && client <= MaxClients)
	{
		g_fReloadHold[client] = 0.0;
		g_bReloadFired[client] = false;
		g_bMenuOpen[client] = false;
		g_bVoteActive[client] = false;
	}
}

// ==================== 菜单构建 ====================

void BuildMenu()
{
	if (g_Items != null)
		delete g_Items;
	if (g_Cats != null)
		delete g_Cats;
	if (g_SubCats != null)
		delete g_SubCats;
	g_Items = new ArrayList(sizeof(MenuItem));
	g_Cats = new ArrayList(sizeof(MenuCat));
	g_SubCats = new ArrayList(sizeof(MenuSubCat));

	// 重建 = 配置已变，清空所有玩家勾选状态（防残留污染）
	for (int p = 1; p <= MaxClients; p++)
	{
		for (int i = 0; i < MAX_MENU_ITEMS; i++)
			g_Selected[p][i] = false;
	}

	if (!ParseVoteManagerCfg())
	{
		LogError("[!v2] vote_manager.cfg 解析失败，菜单未构建");
		g_bMenuBuilt = false;
		return;
	}

	g_bMenuBuilt = true;
	LogMessage("[!v2] 菜单构建完成：%d 分类 / %d 子分类 / %d 选项（vote_manager.cfg 驱动）", g_Cats.Length, g_SubCats.Length, g_Items.Length);
}

// 解析 vote_manager.cfg（文本行解析，格式：缩进 + 大括号层级）
//   "VoteMenu" { "分类" { "子分类" { "选项" "exec xxx.cfg" } | "选项" "exec xxx.cfg" } }
bool ParseVoteManagerCfg()
{
	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), VM_CFG_PATH);
	if (!FileExists(sPath))
	{
		LogError("[!v2] 配置文件不存在: %s", sPath);
		return false;
	}

	File f = OpenFile(sPath, "r");
	if (f == null)
	{
		LogError("[!v2] 配置文件打开失败: %s", sPath);
		return false;
	}

	int depth = 0;          // 大括号深度（根 VoteMenu = 0）
	int catIndex = -1;      // 当前一级分类（-1 = 未进入）
	int subIndex = -1;      // 当前二级子分类（-1 = 不在子分类）
	int subCount = 0;

	char sLine[512];
	while (!f.EndOfFile() && f.ReadLine(sLine, sizeof(sLine)))
	{
		TrimString(sLine);
		if (sLine[0] == '\0')
			continue;

		// 纯 { 行：进入下一层
		if (sLine[0] == '{' && sLine[1] == '\0')
		{
			depth++;
			continue;
		}

		// 纯 } 行：关闭一层（depth 是当前所在层级，闭合该层）
		if (sLine[0] == '}')
		{
			if (depth == 0)
			{
				// 防御：根之上出现 }，忽略（避免 depth 变负导致后续解析全乱）
				continue;
			}
			if (depth == 3 && subIndex >= 0)
			{
				// 关闭子分类：写入 item_count、清除 subIndex
				MenuSubCat sub;
				g_SubCats.GetArray(subIndex, sub);
				sub.item_count = subCount;
				g_SubCats.SetArray(subIndex, sub);
				subIndex = -1;
			}
			else if (depth == 2)
			{
				// 关闭分类：防御性收尾未闭合的子分类（配置缺 } 时兜底）
				if (subIndex >= 0)
				{
					MenuSubCat sub;
					g_SubCats.GetArray(subIndex, sub);
					sub.item_count = subCount;
					g_SubCats.SetArray(subIndex, sub);
					subIndex = -1;
				}
				catIndex = -1;
			}
			else if (depth == 1 && catIndex >= 0)
			{
				catIndex = -1;
			}
			depth--;
			continue;
		}

		// 行尾带 {（"名" { 同行兼容）：解析本行后 depth++
		int len = strlen(sLine);
		bool hasBrace = (sLine[len - 1] == '{');
		if (hasBrace)
		{
			sLine[len - 1] = '\0';
			TrimString(sLine);
		}

		switch (depth)
		{
			case 1:
			{
				// ===== 一级分类名 =====
				char sCat[64];
				ExtractQuoted(sLine, sCat, sizeof(sCat));
				if (sCat[0] == '\0')
					break;

				MenuCat cat;
				strcopy(cat.name, sizeof(cat.name), sCat);
				cat.first_sub = g_SubCats.Length;
				cat.sub_count = 0;
				cat.first_item_row = g_Items.Length;
				cat.item_count = 0;
				catIndex = g_Cats.PushArray(cat);
			}
			case 2:
			{
				// ===== 二级子分类名 或 叶子选项（判断行内是否有值）=====
				char sName[128], sVal[512];
				ExtractQuoted(sLine, sName, sizeof(sName));
				if (sName[0] == '\0')
					break;

				// 行内有第二个引号对 = 叶子选项（"名" "值"）
				bool hasValue = CountQuotes(sLine) >= 4;
				if (hasValue)
				{
					ExtractSecondQuoted(sLine, sVal, sizeof(sVal));
					if (sVal[0] != '\0' && catIndex >= 0)
					{
						MenuItem item;
						strcopy(item.display, sizeof(item.display), sName);
						strcopy(item.exec_on, sizeof(item.exec_on), sVal);
						item.is_ff = (StrContains(sName, "友伤") != -1 || StrContains(sName, "火伤") != -1 ||
						              StrContains(sName, "反伤") != -1 || StrContains(sName, "同伤") != -1);
						MenuCat cat;
						g_Cats.GetArray(catIndex, cat);
						// 分类内首个叶子选项：记录起始行（兼容"先子分类后叶子"混合结构）
						if (cat.item_count == 0)
							cat.first_item_row = g_Items.Length;
						cat.item_count++;
						g_Cats.SetArray(catIndex, cat);
						g_Items.PushArray(item);
					}
				}
				else
				{
					// 二级子分类名
					MenuSubCat sub;
					strcopy(sub.name, sizeof(sub.name), sName);
					sub.cat_index = catIndex;
					sub.first_item_row = g_Items.Length;
					sub.item_count = 0;
					subIndex = g_SubCats.PushArray(sub);
					subCount = 0;
					if (catIndex >= 0)
					{
						MenuCat cat;
						g_Cats.GetArray(catIndex, cat);
						cat.sub_count++;
						g_Cats.SetArray(catIndex, cat);
					}
				}
			}
			case 3:
			{
				// ===== 子分类内的选项（"名" "值"）=====
				if (subIndex < 0)
					break;
				char sOpt[128], sVal[512];
				ExtractQuoted(sLine, sOpt, sizeof(sOpt));
				if (sOpt[0] == '\0')
					break;
				ExtractSecondQuoted(sLine, sVal, sizeof(sVal));
				if (sVal[0] == '\0')
					break;

				MenuItem item;
				strcopy(item.display, sizeof(item.display), sOpt);
				strcopy(item.exec_on, sizeof(item.exec_on), sVal);
				item.is_ff = (StrContains(sOpt, "友伤") != -1 || StrContains(sOpt, "火伤") != -1 ||
				              StrContains(sOpt, "反伤") != -1 || StrContains(sOpt, "同伤") != -1);
				g_Items.PushArray(item);
				subCount++;
			}
		}

		if (hasBrace)
			depth++;
	}
	// 处理文件尾未闭合的子分类（防御）
	if (subIndex >= 0)
	{
		MenuSubCat sub;
		g_SubCats.GetArray(subIndex, sub);
		sub.item_count = subCount;
		g_SubCats.SetArray(subIndex, sub);
	}

	delete f;
	LogMessage("[!v2] vote_manager.cfg 解析完成：%d 分类 / %d 子分类 / %d 选项", g_Cats.Length, g_SubCats.Length, g_Items.Length);
	return g_Items.Length > 0;
}

// 提取行内第一个引号对的内容
void ExtractQuoted(const char[] sLine, char[] buffer, int maxlen)
{
	buffer[0] = '\0';
	int len = strlen(sLine);
	int start = -1;
	for (int i = 0; i < len; i++)
	{
		if (sLine[i] == '"')
		{
			start = i + 1;
			break;
		}
	}
	if (start < 0)
		return;
	for (int i = start; i < len; i++)
	{
		if (sLine[i] == '"')
		{
			int n = i - start;
			if (n >= maxlen)
				n = maxlen - 1;
			strcopy(buffer, n + 1, sLine[start]);
			return;
		}
	}
}

// 提取行内第二个引号对的内容（值）
void ExtractSecondQuoted(const char[] sLine, char[] buffer, int maxlen)
{
	buffer[0] = '\0';
	int len = strlen(sLine);
	int quotes = 0;
	int start = -1;
	for (int i = 0; i < len; i++)
	{
		if (sLine[i] == '"')
		{
			quotes++;
			if (quotes == 3)
			{
				start = i + 1;
				break;
			}
		}
	}
	if (start < 0)
		return;
	for (int i = start; i < len; i++)
	{
		if (sLine[i] == '"')
		{
			int n = i - start;
			if (n >= maxlen)
				n = maxlen - 1;
			strcopy(buffer, n + 1, sLine[start]);
			return;
		}
	}
}

// 统计行内引号数量
int CountQuotes(const char[] sLine)
{
	int count = 0;
	int len = strlen(sLine);
	for (int i = 0; i < len; i++)
	{
		if (sLine[i] == '"')
			count++;
	}
	return count;
}

// ==================== 菜单（Panel 方案：数字键 1-5 选择 / 6 投票 / 7 返回 / 8 9 翻页）====================

public Action Cmd_V2(int client, int args)
{
	if (client <= 0 || !IsClientInGame(client))
		return Plugin_Handled;

	OpenMainMenu(client);
	return Plugin_Handled;
}

public Action Cmd_V2Reload(int client, int args)
{
	BuildMenu();
	ReplyToCommand(client, "[!v2] 已重新读取 vote_manager.cfg（%d 分类 / %d 选项）", g_Cats != null ? g_Cats.Length : 0, g_Items != null ? g_Items.Length : 0);
	return Plugin_Handled;
}

void StartMenuTimer()
{
	if (g_hMenuTimer == null)
	{
		g_hMenuTimer = CreateTimer(1.0, Timer_MenuRefresh, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	}
}

public Action Timer_MenuRefresh(Handle timer)
{
	if (timer != g_hMenuTimer)
		return Plugin_Stop;

	bool anyOpen = false;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (g_bMenuOpen[i])
		{
			anyOpen = true;
			// 投票进行中：不检测超时、不重画 Panel（避免与原生投票抢屏）
			if (g_bVoteActive[i])
				continue;
			// 30 秒无操作自动关闭
			if (GetSysTickCount() - g_iMenuOpenTime[i] > MENU_TIMEOUT)
			{
				g_bMenuOpen[i] = false;
				PrintToChat(i, "\x04[!v2]\x01 菜单超时自动关闭（30秒无操作）");
				continue;
			}
			ShowMenuPanel(i);   // 每秒重画保持显示（Panel time=1 秒）
		}
	}
	if (!anyOpen && g_hMenuTimer != null)
	{
		KillTimer(g_hMenuTimer);
		g_hMenuTimer = null;
	}
	return Plugin_Continue;
}

void OpenMainMenu(int client)
{
	if (g_Items == null || !g_bMenuBuilt)
	{
		CPrintToChat(client, "{blue}[!v2] {default}菜单未就绪（配置解析失败）");
		return;
	}

	// 提示已选数量
	int picked = 0;
	for (int i = 0; i < g_Items.Length; i++)
	{
		if (g_Selected[client][i])
			picked++;
	}
	if (picked > 0)
		CPrintToChat(client, "{blue}[!v2] {default}当前已勾选 {green}%d{default} 项，按 {green}6{default} 发起投票", picked);

	g_iMenuLevel[client] = Level_Main;
	g_iMenuIndex[client] = 0;
	g_iMenuPage[client] = 0;
	g_iMenuOpenTime[client] = GetSysTickCount();
	g_bMenuOpen[client] = true;
	StartMenuTimer();
	ShowMenuPanel(client);
}

// 当前层级的条目总数（纯内容项，按钮固定按键不占槽位）
int GetItemCount(int client)
{
	if (g_iMenuLevel[client] == Level_Main)
	{
		return g_Cats.Length;
	}
	else if (g_iMenuLevel[client] == Level_Cat)
	{
		int catIdx = g_iMenuIndex[client];
		MenuCat cat;
		g_Cats.GetArray(catIdx, cat);
		return cat.sub_count + cat.item_count;
	}
	else
	{
		MenuSubCat sub;
		g_SubCats.GetArray(g_iMenuIndex[client], sub);
		return sub.item_count;
	}
}

void ShowMenuPanel(int client)
{
	if (!g_bMenuOpen[client] || !IsClientInGame(client))
		return;

	Panel p = new Panel();
	char sBuf[256];

	// ===== 主菜单（纯内容：分类列表，按钮固定按键 6投票 7关闭）=====
	if (g_iMenuLevel[client] == Level_Main)
	{
		p.DrawText("服务器设置");
		p.DrawText(" ");

		int items = g_Cats.Length;
		int totalPages = (items + PANEL_OPTIONS_PER_PAGE - 1) / PANEL_OPTIONS_PER_PAGE;
		if (totalPages < 1) totalPages = 1;
		if (g_iMenuPage[client] >= totalPages)
			g_iMenuPage[client] = totalPages - 1;
		if (g_iMenuPage[client] < 0)
			g_iMenuPage[client] = 0;
		int start = g_iMenuPage[client] * PANEL_OPTIONS_PER_PAGE;

		for (int i = start; i < start + PANEL_OPTIONS_PER_PAGE && i < items; i++)
		{
			int key = i - start + 1;
			MenuCat cat;
			g_Cats.GetArray(i, cat);
			int cnt = cat.item_count;
			for (int s = cat.first_sub; s < cat.first_sub + cat.sub_count && s < g_SubCats.Length; s++)
			{
				MenuSubCat sub;
				g_SubCats.GetArray(s, sub);
				cnt += sub.item_count;
			}
			FormatEx(sBuf, sizeof(sBuf), "%d. %s (%d)", key, cat.name, cnt);
			p.DrawText(sBuf);
		}

		p.DrawText(" ");
		FormatEx(sBuf, sizeof(sBuf), "1-5选择 6投票 7关闭 8/9翻页%s", totalPages > 1 ? "" : "");
		p.DrawText(sBuf);
	}
	// ===== 分类菜单（纯内容：子分类+叶子选项）=====
	else if (g_iMenuLevel[client] == Level_Cat)
	{
		int catIdx = g_iMenuIndex[client];
		MenuCat cat;
		g_Cats.GetArray(catIdx, cat);
		p.DrawText(cat.name);
		p.DrawText(" ");

		int items = cat.sub_count + cat.item_count;
		int totalPages = (items + PANEL_OPTIONS_PER_PAGE - 1) / PANEL_OPTIONS_PER_PAGE;
		if (totalPages < 1) totalPages = 1;
		if (g_iMenuPage[client] >= totalPages)
			g_iMenuPage[client] = totalPages - 1;
		if (g_iMenuPage[client] < 0)
			g_iMenuPage[client] = 0;
		int start = g_iMenuPage[client] * PANEL_OPTIONS_PER_PAGE;

		for (int i = start; i < start + PANEL_OPTIONS_PER_PAGE && i < items; i++)
		{
			int key = i - start + 1;
			int slot = i;
			if (slot < cat.sub_count)
			{
				int subIdx = cat.first_sub + slot;
				MenuSubCat sub;
				g_SubCats.GetArray(subIdx, sub);
				FormatEx(sBuf, sizeof(sBuf), "%d. ▸ %s (%d)", key, sub.name, sub.item_count);
			}
			else
			{
				int row = cat.first_item_row + (slot - cat.sub_count);
				MenuItem item;
				g_Items.GetArray(row, item);
				FormatEx(sBuf, sizeof(sBuf), "%d. %s %s", key, g_Selected[client][row] ? "[●]" : "[○]", item.display);
			}
			p.DrawText(sBuf);
		}

		p.DrawText(" ");
		FormatEx(sBuf, sizeof(sBuf), "1-5选择 6投票 7返回 8/9翻页");
		p.DrawText(sBuf);
	}
	// ===== 子分类菜单（纯内容：选项勾选）=====
	else
	{
		int subIdx = g_iMenuIndex[client];
		MenuSubCat sub;
		g_SubCats.GetArray(subIdx, sub);
		p.DrawText(sub.name);
		p.DrawText(" ");

		int items = sub.item_count;
		int totalPages = (items + PANEL_OPTIONS_PER_PAGE - 1) / PANEL_OPTIONS_PER_PAGE;
		if (totalPages < 1) totalPages = 1;
		if (g_iMenuPage[client] >= totalPages)
			g_iMenuPage[client] = totalPages - 1;
		if (g_iMenuPage[client] < 0)
			g_iMenuPage[client] = 0;
		int start = g_iMenuPage[client] * PANEL_OPTIONS_PER_PAGE;

		for (int i = start; i < start + PANEL_OPTIONS_PER_PAGE && i < items; i++)
		{
			int key = i - start + 1;
			int row = sub.first_item_row + i;
			MenuItem item;
			g_Items.GetArray(row, item);
			FormatEx(sBuf, sizeof(sBuf), "%d. %s %s", key, g_Selected[client][row] ? "[●]" : "[○]", item.display);
			p.DrawText(sBuf);
		}

		p.DrawText(" ");
		FormatEx(sBuf, sizeof(sBuf), "1-5选择 6投票 7返回 8/9翻页");
		p.DrawText(sBuf);
	}

	p.Send(client, MenuPanelHandler, 1);
	delete p;
}

// ===== Panel 按键处理（1-5 选择 / 6 投票 / 7 返回关闭 / 8 9 翻页）=====
public int MenuPanelHandler(Panel panel, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_Select)
	{
		int client = param1;
		if (client < 1 || client > MaxClients || !IsClientInGame(client))
			return 0;
		if (!g_bMenuOpen[client])
			return 0;

		g_iMenuOpenTime[client] = GetSysTickCount();  // 活动重置超时

		int key = param2;
		int items = GetItemCount(client);
		int totalPages = (items + PANEL_OPTIONS_PER_PAGE - 1) / PANEL_OPTIONS_PER_PAGE;
		if (totalPages < 1) totalPages = 1;

		if (key >= 1 && key <= 5)
		{
			int idx = g_iMenuPage[client] * PANEL_OPTIONS_PER_PAGE + (key - 1);
			if (idx >= 0 && idx < items)
			{
				HandleEntry(client, idx);
			}
		}
		else if (key == 6)
		{
			// 发起投票（当前层级范围）
			StartVoteByLevel(client);
		}
		else if (key == 7)
		{
			// 返回上级 / 主菜单关闭
			GoBack(client);
		}
		else if (key == 8)
		{
			if (g_iMenuPage[client] > 0)
			{
				g_iMenuPage[client]--;
				ShowMenuPanel(client);
			}
		}
		else if (key == 9)
		{
			if (g_iMenuPage[client] < totalPages - 1)
			{
				g_iMenuPage[client]++;
				ShowMenuPanel(client);
			}
		}
	}
	return 0;
}

void HandleEntry(int client, int idx)
{
	if (g_iMenuLevel[client] == Level_Main)
	{
		// idx = 分类索引（按钮 6=投票 7=关闭 固定按键）
		if (idx >= 0 && idx < g_Cats.Length)
		{
			LogMessage("[!v2] 主菜单->分类: client=%N cat=%d", client, idx);
			g_iMenuLevel[client] = Level_Cat;
			g_iMenuIndex[client] = idx;
			g_iMenuPage[client] = 0;
			ShowMenuPanel(client);
		}
	}
	else if (g_iMenuLevel[client] == Level_Cat)
	{
		int catIdx = g_iMenuIndex[client];
		MenuCat cat;
		g_Cats.GetArray(catIdx, cat);

		if (idx < cat.sub_count)
		{
			int subIdx = cat.first_sub + idx;
			MenuSubCat sub;
			g_SubCats.GetArray(subIdx, sub);
			LogMessage("[!v2] 分类->子分类: client=%N cat=%d sub=%d", client, catIdx, subIdx);
			g_iMenuLevel[client] = Level_Sub;
			g_iMenuIndex[client] = subIdx;
			g_iMenuPage[client] = 0;
			ShowMenuPanel(client);
		}
		else
		{
			int row = cat.first_item_row + (idx - cat.sub_count);
			ToggleSelect(client, row);
			ShowMenuPanel(client);
		}
	}
	else
	{
		int subIdx = g_iMenuIndex[client];
		MenuSubCat sub;
		g_SubCats.GetArray(subIdx, sub);

		int row = sub.first_item_row + idx;
		ToggleSelect(client, row);
		ShowMenuPanel(client);
	}
}

void GoBack(int client)
{
	if (g_iMenuLevel[client] == Level_Main)
	{
		// 主菜单：关闭
		g_bMenuOpen[client] = false;
	}
	else if (g_iMenuLevel[client] == Level_Cat)
	{
		g_iMenuLevel[client] = Level_Main;
		g_iMenuPage[client] = 0;
		ShowMenuPanel(client);
	}
	else
	{
		MenuSubCat sub;
		g_SubCats.GetArray(g_iMenuIndex[client], sub);
		int catIdx = sub.cat_index;
		if (catIdx >= 0 && catIdx < g_Cats.Length)
		{
			g_iMenuLevel[client] = Level_Cat;
			g_iMenuIndex[client] = catIdx;
			g_iMenuPage[client] = 0;
			ShowMenuPanel(client);
		}
	}
}

void ToggleSelect(int client, int row)
{
	if (row < 0 || row >= g_Items.Length)
		return;
	g_Selected[client][row] = !g_Selected[client][row];
	MenuItem item;
	g_Items.GetArray(row, item);
	LogMessage("[!v2] 勾选切换: client=%N item=%s value=%d", client, item.display, g_Selected[client][row] ? 1 : 0);
}

void StartVoteByLevel(int client)
{
	if (g_iMenuLevel[client] == Level_Main)
	{
		LogMessage("[!v2] 主菜单按6发起全部投票: client=%N", client);
		StartVote(client, VoteScope_All, -1);
	}
	else if (g_iMenuLevel[client] == Level_Cat)
	{
		LogMessage("[!v2] 分类菜单按6发起投票: client=%N cat=%d", client, g_iMenuIndex[client]);
		StartVote(client, VoteScope_Cat, g_iMenuIndex[client]);
	}
	else
	{
		LogMessage("[!v2] 子分类菜单按6发起投票: client=%N sub=%d", client, g_iMenuIndex[client]);
		StartVote(client, VoteScope_SubCat, g_iMenuIndex[client]);
	}
}

// ==================== 长按 R 呼出 ====================

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
	if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
		return Plugin_Continue;

	// 菜单打开中不检测
	if (g_bMenuOpen[client] || !g_bMenuBuilt)
	{
		if (!(buttons & IN_RELOAD))
		{
			g_fReloadHold[client] = 0.0;
			g_bReloadFired[client] = false;
		}
		return Plugin_Continue;
	}

	if (buttons & IN_RELOAD)
	{
		if (g_fReloadHold[client] == 0.0)
		{
			g_fReloadHold[client] = GetEngineTime();
		}
		else if (!g_bReloadFired[client] && GetEngineTime() - g_fReloadHold[client] >= RELOAD_HOLD_TIME)
		{
			g_bReloadFired[client] = true;
			CPrintToChat(client, "{blue}[!v2] {default}长按 {green}R{default} 呼出设置菜单");
			OpenMainMenu(client);
		}
	}
	else
	{
		g_fReloadHold[client] = 0.0;
		g_bReloadFired[client] = false;
	}

	return Plugin_Continue;
}

// ==================== 聚合投票 ====================

void StartVote(int client, VoteScope scope, int index)
{
	if (g_Items == null)
		return;

	// 确定收集范围
	int startRow = 0;
	int endRow = g_Items.Length;
	char sTitle[256];

	if (scope == VoteScope_Cat)
	{
		if (index < 0 || index >= g_Cats.Length)
			return;
		MenuCat cat;
		g_Cats.GetArray(index, cat);
		startRow = cat.first_item_row;
		endRow = startRow + cat.item_count;
		for (int s = cat.first_sub; s < cat.first_sub + cat.sub_count && s < g_SubCats.Length; s++)
		{
			MenuSubCat sub;
			g_SubCats.GetArray(s, sub);
			if (sub.first_item_row < startRow)
				startRow = sub.first_item_row;
			if (sub.first_item_row + sub.item_count > endRow)
				endRow = sub.first_item_row + sub.item_count;
		}
		Format(sTitle, sizeof(sTitle), "%s 设置：", cat.name);
	}
	else if (scope == VoteScope_SubCat)
	{
		if (index < 0 || index >= g_SubCats.Length)
			return;
		MenuSubCat sub;
		g_SubCats.GetArray(index, sub);
		startRow = sub.first_item_row;
		endRow = startRow + sub.item_count;
		MenuCat cat;
		if (sub.cat_index >= 0 && sub.cat_index < g_Cats.Length)
			g_Cats.GetArray(sub.cat_index, cat);
		Format(sTitle, sizeof(sTitle), "%s-%s：", cat.name, sub.name);
	}
	else
	{
		Format(sTitle, sizeof(sTitle), "服务器设置：");
	}

	// 收集勾选项
	if (g_VoteItems != null)
		delete g_VoteItems;
	g_VoteItems = new ArrayList(512);
	if (g_VoteFF != null)
		delete g_VoteFF;
	g_VoteFF = new ArrayList();
	g_bVoteNeedRestart = false;

	int picked = 0;
	for (int i = startRow; i < endRow && i < g_Items.Length; i++)
	{
		if (!g_Selected[client][i])
			continue;

		MenuItem item;
		g_Items.GetArray(i, item);
		if (item.exec_on[0] == '\0')
			continue;

		g_VoteItems.PushString(item.exec_on);
		g_VoteFF.Push(item.is_ff ? 1 : 0);
		if (picked > 0)
			StrCat(sTitle, sizeof(sTitle), "、");
		StrCat(sTitle, sizeof(sTitle), item.display);
		picked++;
	}

	if (picked == 0)
	{
		CPrintToChat(client, "{blue}[!v2] {default}请先勾选至少一个选项再发起投票！");
		return;
	}

	LogMessage("[!v2] 投票收集: client=%N 勾选=%s", client, sTitle);

	// 生成整合 cfg（内含 restart 自动检测）
	if (!BuildIntegratedCfg())
	{
		CPrintToChat(client, "{red}[!v2] {default}整合配置生成失败！");
		return;
	}
	LogMessage("[!v2] 整合cfg生成成功 need_restart=%s", g_bVoteNeedRestart ? "YES" : "no");

	// 勾选状态保留（所见即所得）：玩家手动取消，或再次发起投票

	if (!L4D2NativeVote_IsAllowNewVote())
	{
		CPrintToChat(client, "{blue}[!v2] {default}已有投票正在进行，请稍后再试");
		return;
	}

	int[] clients = new int[MaxClients];
	int numClients = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i))
			clients[numClients++] = i;
	}

	L4D2NativeVote vote = L4D2NativeVote(VoteHandler);
	vote.SetTitle("执行：%s", sTitle);
	vote.Initiator = client;
	if (!vote.DisplayVote(clients, numClients, 20))
	{
		CPrintToChat(client, "{red}[!v2] {default}投票发起失败");
		return;
	}

	// 投票已成功显示：记录发起者 + 标记投票中（暂停该玩家菜单超时/重画，避免投票期间菜单被误关）
	g_iVoteInitiator = client;
	g_bVoteActive[client] = true;
}

// 智能整合：读选中 cfg 内容 -> load 去重 -> restartmap/refresh 后置 -> 友伤火伤最后覆盖
bool BuildIntegratedCfg()
{
	if (g_VoteItems == null || g_VoteItems.Length == 0)
		return false;

	File f = OpenFile(INTEGRATED_CFG, "w");
	if (f == null)
		return false;

	f.WriteLine("// ================================================");
	f.WriteLine("// !v2 聚合投票整合配置（自动生成）");
	f.WriteLine("// ================================================");

	ArrayList seenLoad = new ArrayList(256);
	ArrayList seenAll = new ArrayList(512);
	ArrayList ffLines = new ArrayList(512);
	ArrayList ffSeen = new ArrayList(512);

	for (int i = 0; i < g_VoteItems.Length; i++)
	{
		char sExec[512];
		g_VoteItems.GetString(i, sExec, sizeof(sExec));
		bool isFF = (g_VoteFF != null && i < g_VoteFF.Length && g_VoteFF.Get(i) == 1);

		if (StrContains(sExec, "exec ") == 0)
		{
			char sPath[512];
			strcopy(sPath, sizeof(sPath), sExec[5]);
			TrimString(sPath);
			char sReadPath[512];
			Format(sReadPath, sizeof(sReadPath), "cfg/%s", sPath);
			File rf = OpenFile(sReadPath, "r");
			if (rf != null)
			{
				char sLine[512];
				while (!rf.EndOfFile() && rf.ReadLine(sLine, sizeof(sLine)))
				{
					TrimString(sLine);
					if (sLine[0] == '\0' || (sLine[0] == '/' && sLine[1] == '/'))
						continue;
					// 自动检测 restartmap：cfg 内容含 sm_restartmap 则该投票需要重启地图
					if (StrContains(sLine, "sm_restartmap") == 0 || strcmp(sLine, "restartmap") == 0)
					{
						g_bVoteNeedRestart = true;
						continue;
					}
				if (isFF)
					MergeLineFF(f, sLine, seenLoad, ffLines, ffSeen);
				else
					MergeLine(f, sLine, seenLoad, seenAll);
				}
				delete rf;
			}
		}
		else
		{
			if (StrContains(sExec, "sm_restartmap") == 0 || strcmp(sExec, "restartmap") == 0)
			{
				g_bVoteNeedRestart = true;
				continue;
			}
			if (isFF)
				MergeLineFF(f, sExec, seenLoad, ffLines, ffSeen);
			else
				MergeLine(f, sExec, seenLoad, seenAll);
		}
	}

	// 友伤/火伤行最后覆盖
	for (int i = 0; i < ffLines.Length; i++)
	{
		char sFF[512];
		ffLines.GetString(i, sFF, sizeof(sFF));
		f.WriteLine("%s", sFF);
	}

	// 末尾统一 refresh；仅当勾选项 cfg 里有 restartmap 才加
	f.WriteLine("sm plugins refresh");
	if (g_bVoteNeedRestart)
		f.WriteLine("sm_restartmap");

	delete seenLoad;
	delete seenAll;
	delete ffLines;
	delete ffSeen;
	delete f;
	return true;
}

void MergeLine(File f, const char[] sLine, ArrayList seenLoad, ArrayList seenAll)
{
	if (sLine[0] == '\0')
		return;

	if (StrContains(sLine, "sm plugins load") == 0)
	{
		if (seenLoad.FindString(sLine) == -1)
		{
			seenLoad.PushString(sLine);
			f.WriteLine("%s", sLine);
		}
		return;
	}

	if (StrContains(sLine, "sm_restartmap") == 0 || strcmp(sLine, "restartmap") == 0)
		return;

	if (StrContains(sLine, "sm plugins refresh") == 0)
		return;

	if (seenAll.FindString(sLine) == -1)
	{
		seenAll.PushString(sLine);
		f.WriteLine("%s", sLine);
	}
}

// 友伤/火伤行：不立即写，收集到 ffLines 最后覆盖
void MergeLineFF(File f, const char[] sLine, ArrayList seenLoad, ArrayList ffLines, ArrayList ffSeen)
{
	if (sLine[0] == '\0')
		return;

	if (StrContains(sLine, "sm plugins load") == 0)
	{
		if (seenLoad.FindString(sLine) == -1)
		{
			seenLoad.PushString(sLine);
			f.WriteLine("%s", sLine);
		}
		return;
	}

	if (StrContains(sLine, "sm_restartmap") == 0 || strcmp(sLine, "restartmap") == 0)
		return;

	if (StrContains(sLine, "sm plugins refresh") == 0)
		return;

	if (ffSeen.FindString(sLine) == -1)
	{
		ffSeen.PushString(sLine);
		ffLines.PushString(sLine);
	}
}

int VoteHandler(L4D2NativeVote vote, VoteAction action, int param1, int param2)
{
	switch (action)
	{
		case VoteAction_Start:
		{
			CPrintToChatAllEx(param1, "{green}[!v2] {default}%N 发起设置投票！", param1);
		}
		case VoteAction_PlayerVoted:
		{
			CPrintToChatAllEx(param1, "{green}[!v2] {default}%N 已投票", param1);
		}
		case VoteAction_End:
		{
			// 投票结束：清理投票状态，菜单干净关闭（玩家需要时重输 !v2）
			int initiator = g_iVoteInitiator;
			if (initiator > 0 && initiator <= MaxClients)
			{
				g_bVoteActive[initiator] = false;
				g_bMenuOpen[initiator] = false;
			}
			g_iVoteInitiator = 0;

			if (vote.YesCount > vote.NoCount)
			{
				ServerCommand("exec vote/v2_integrated.cfg");
				CPrintToChatAll("{green}[!v2] {default}投票通过，已执行整合配置！");
				vote.SetPass();
			}
			else
			{
				CPrintToChatAll("{blue}[!v2] {default}投票未通过");
				vote.SetFail();
			}
		}
	}
	return 0;
}
