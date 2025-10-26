/**
 * pvs_amplify.sp
 * SourceMod 1.12 (CS2) — safe research plugin
 *
 * - Server-side LOS checks (multi-sample)
 * - Team aggregation
 * - Compact broadcast of spotted entries (no coordinates)
 */

#pragma semicolon 1
#include <sourcemod>
#include <sdktools_trace>
#include <sdkhooks>
#include <math>

public Plugin myinfo =
{
    name = "pvs_amplify_research",
    author = "Research",
    description = "Server-side LOS-based spotted system (research demo)",
    version = "0.1"
};

#define SPOT_EXPIRY        3.0
#define CHECK_INTERVAL     0.10
#define BROADCAST_INTERVAL 0.25
#define MAX_LOS_SAMPLES    4

Handle gTeamSpotted;
new Float:gCachedVisibility[133][133];

public void OnPluginStart()
{
    gTeamSpotted = CreateTrie();
    CreateTimer(CHECK_INTERVAL, Timer_CheckLOS, _, TIMER_REPEAT);
    CreateTimer(BROADCAST_INTERVAL, Timer_Broadcast, _, TIMER_REPEAT);
    HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);
    HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Post);
}

public Action Timer_CheckLOS(Handle timer)
{
    float now = GetEngineTime();

    for (int v = 1; v <= MaxClients; v++)
    {
        if (!IsClientInGame(v) || !IsPlayerAlive(v)) continue;
        int vTeam = GetClientTeam(v);
        float vEye[3]; GetClientEyePosition(v, vEye);

        for (int t = 1; t <= MaxClients; t++)
        {
            if (!IsClientInGame(t) || !IsPlayerAlive(t) || t == v) continue;
            if (GetClientTeam(t) == vTeam) continue;

            // Quick cache check
            if (gCachedVisibility[v][t] > now)
            {
                MarkTeamSpotted(vTeam, t, now, SPOT_EXPIRY);
                continue;
            }

            bool visible = IsVisibleTo(v, t);
            if (visible)
            {
                gCachedVisibility[v][t] = now + SPOT_EXPIRY;
                MarkTeamSpotted(vTeam, t, now, SPOT_EXPIRY);
            }
            else
            {
                gCachedVisibility[v][t] = 0.0;
            }
        }
    }
    return Plugin_Continue;
}

bool IsVisibleTo(int viewer, int target)
{
    float eye[3]; GetClientEyePosition(viewer, eye);
    float sample[3];

    // Sample head
    GetClientEyePosition(target, sample);
    if (TraceLOS(eye, sample, viewer, target)) return true;

    // Sample chest
    GetClientAbsOrigin(target, sample);
    sample[2] += 36.0;
    if (TraceLOS(eye, sample, viewer, target)) return true;

    // Sample legs
    sample[2] -= 26.0;
    if (TraceLOS(eye, sample, viewer, target)) return true;

    // Offsets
    sample[0] += 12.0; sample[1] += 0.0; sample[2] += 12.0;
    if (TraceLOS(eye, sample, viewer, target)) return true;

    sample[0] -= 24.0;
    if (TraceLOS(eye, sample, viewer, target)) return true;

    return false;
}

bool TraceLOS(float start[3], float end[3], int viewer, int expectedTarget)
{
    Handle tr = TR_TraceRayFilterEx(start, end, MASK_SOLID, RayType_EndPoint, TraceFilter, viewer);
    bool hit = TR_DidHit(tr);
    int ent = TR_GetEntityIndex(tr);
    CloseHandle(tr);
    return (!hit || ent == expectedTarget);
}

public bool TraceFilter(int entIndex, int contentsMask, any data)
{
    int viewer = data;
    if (entIndex == viewer) return false;
    return true;
}

public void MarkTeamSpotted(int team, int enemy, float now, float expiry)
{
    if (team <= 0) return;
    char key[8];
    IntToString(team, key, sizeof(key));
    Handle arr = TrieGetHandle(gTeamSpotted, key);
    if (arr == INVALID_HANDLE)
    {
        arr = CreateArray(3);
        TrieSetHandle(gTeamSpotted, key, arr);
    }

    int len = GetArraySize(arr);
    for (int i = 0; i < len; i += 3)
    {
        int storedId = GetArrayCell(arr, i + 0);
        if (storedId == enemy)
        {
            SetArrayCell(arr, i + 1, FloatToCell(now + expiry));
            return;
        }
    }

    PushArrayCell(arr, enemy);
    PushArrayCell(arr, FloatToCell(now + expiry));
    PushArrayCell(arr, 0);
}

public Action Timer_Broadcast(Handle timer)
{
    float now = GetEngineTime();
    Handle iter = CreateTrieIterator(gTeamSpotted);
    char key[8];
    while (TrieIteratorNext(iter, key, sizeof(key)))
    {
        Handle arr = TrieGetHandle(gTeamSpotted, key);
        if (arr == INVALID_HANDLE) continue;
        int len = GetArraySize(arr);
        if (len == 0) continue;

        int team = StringToInt(key);
        for (int i = 1; i <= MaxClients; i++)
        {
            if (!IsClientInGame(i)) continue;
            if (GetClientTeam(i) != team) continue;

            // Start usermessage 'pvs_spotted' (compact)
            StartMessage("pvs_spotted", i);
            WriteFloat(now);
            WriteByte(len / 3);
            for (int j = 0; j < len; j += 3)
            {
                int enemyId = GetArrayCell(arr, j + 0);
                float expiry = CellToFloat(GetArrayCell(arr, j + 1));
                int zone = GetArrayCell(arr, j + 2);
                WriteShort(enemyId);
                WriteFloat(expiry);
                WriteShort(zone);
            }
            EndMessage();
        }
    }
    CloseHandle(iter);
    ExpireTeamSpots(now);
    return Plugin_Continue;
}

public void ExpireTeamSpots(float now)
{
    Handle iter = CreateTrieIterator(gTeamSpotted);
    char key[8];
    while (TrieIteratorNext(iter, key, sizeof(key)))
    {
        Handle arr = TrieGetHandle(gTeamSpotted, key);
        if (arr == INVALID_HANDLE) continue;
        int len = GetArraySize(arr);
        for (int i = len - 3; i >= 0; i -= 3)
        {
            float expiry = CellToFloat(GetArrayCell(arr, i + 1));
            if (expiry < now)
            {
                RemoveArrayCell(arr, i + 2);
                RemoveArrayCell(arr, i + 1);
                RemoveArrayCell(arr, i + 0);
            }
        }
    }
    CloseHandle(iter);
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontbroadcast)
{
    int userid = event.GetInt("userid");
    int client = GetClientOfUserId(userid);
    RemovePlayerFromAllTeamSpots(client);
}

public void Event_PlayerDisconnect(Event event, const char[] name, bool dontbroadcast)
{
    int userid = event.GetInt("userid");
    int client = GetClientOfUserId(userid);
    RemovePlayerFromAllTeamSpots(client);
}

public void RemovePlayerFromAllTeamSpots(int player)
{
    Handle iter = CreateTrieIterator(gTeamSpotted);
    char key[8];
    while (TrieIteratorNext(iter, key, sizeof(key)))
    {
        Handle arr = TrieGetHandle(gTeamSpotted, key);
        if (arr == INVALID_HANDLE) continue;
        int len = GetArraySize(arr);
        for (int i = len - 3; i >= 0; i -= 3)
        {
            int storedId = GetArrayCell(arr, i + 0);
            if (storedId == player)
            {
                RemoveArrayCell(arr, i + 2);
                RemoveArrayCell(arr, i + 1);
                RemoveArrayCell(arr, i + 0);
            }
        }
    }
    CloseHandle(iter);
}
