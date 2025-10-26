/**
 * pvs_amplify.sp
 * SourceMod 1.12 (CS2) — tight server-side LOS-based spotting
 *
 * - Aggressive pre-filters: distance, FOV
 * - Multi-sample LOS (head/chest/legs + offsets)
 * - Staggered checks + caching
 * - Team aggregation + compact broadcast (no coords)
 */

#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

public Plugin myinfo =
{
    name = "PVS Amplified (tight)",
    author = "turn-my-swag-on",
    description = "Server-side LOS-based spotted system",
    version = "1.0"
};

/* == Configurable CVars == */
new Handle:gCvar_Enabled;
new Handle:gCvar_CheckInterval;
new Handle:gCvar_BroadcastInterval;
new Handle:gCvar_MaxLosSamples;
new Handle:gCvar_MaxChecksPerTick;
new Handle:gCvar_SpotExpiry;
new Handle:gCvar_DistanceCull;
new Handle:gCvar_FOVCull;

public void OnPluginStart()
{
    gCvar_Enabled = CreateConVar("pvsamp_enabled", "1", "Enable/disable PVS-Amplified spotting");
    gCvar_CheckInterval = CreateConVar("pvsamp_check_interval", "0.08", "Server tick interval to run checks (s)");
    gCvar_BroadcastInterval = CreateConVar("pvsamp_broadcast_interval", "0.20", "How often to broadcast spotted updates (s)");
    gCvar_MaxLosSamples = CreateConVar("pvsamp_max_los_samples", "4", "Max LOS samples per target (head/chest/legs/offset)");
    gCvar_MaxChecksPerTick = CreateConVar("pvsamp_max_checks_per_tick", "512", "Max viewer->target checks per tick (staggered)");
    gCvar_SpotExpiry = CreateConVar("pvsamp_spot_expiry", "3.0", "Seconds before a spot expires");
    gCvar_DistanceCull = CreateConVar("pvsamp_distance_cull", "1500.0", "Max distance (units) to consider LOS");
    gCvar_FOVCull = CreateConVar("pvsamp_fov_cos", "0.5", "Dot-product threshold for FOV cull (cos). 0.5 ~= 60deg");

    CreateTimer(GetConVarFloat(gCvar_CheckInterval), Timer_CheckLOS, _, TIMER_REPEAT);
    CreateTimer(GetConVarFloat(gCvar_BroadcastInterval), Timer_Broadcast, _, TIMER_REPEAT);

    HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Post);
    HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);
}

/* == Internal storage == */
#define MAXPLAYERS_SM 130
new Float:gCachedVisibility[MAXPLAYERS_SM][MAXPLAYERS_SM]; // default 0.0
new Handle:gTeamSpotted; // Trie: key=team string -> Handle to ArrayList of int triples
new cell:gServerTick = 0;

/* == Timer: Check LOS == */
public Action Timer_CheckLOS(Handle timer)
{
    if (GetConVarInt(gCvar_Enabled) == 0) return Plugin_Continue;

    gServerTick++;
    float now = GetEngineTime();

    int maxChecks = GetConVarInt(gCvar_MaxChecksPerTick);
    int checksDone = 0;

    int viewers[128]; int vcount = 0;
    int candidates[128]; int ccount = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || !IsPlayerAlive(i)) continue;
        viewers[vcount++] = i;
        candidates[ccount++] = i;
    }

    int viewerStart = gServerTick % (vcount > 0 ? vcount : 1);
    int candStart   = gServerTick % (ccount > 0 ? ccount : 1);

    for (int vi = 0; vi < vcount && checksDone < maxChecks; vi++)
    {
        int vIndex = (viewerStart + vi) % vcount;
        int viewer = viewers[vIndex];

        if (IsClientObserver(viewer)) continue;

        float vEye[3]; SDKTools_GetClientEyePosition(viewer, vEye);
        float vForward[3]; GetClientForwardVector(viewer, vForward);
        int vTeam = GetClientTeam(viewer);

        int perViewerCap = maxChecks / (vcount > 0 ? vcount : 1);
        int localChecks = 0;

        for (int ci = 0; ci < ccount && localChecks < perViewerCap && checksDone < maxChecks; ci++)
        {
            int tIndex = (candStart + ci) % ccount;
            int target = candidates[tIndex];
            if (target == viewer) continue;
            if (GetClientTeam(target) == vTeam) continue;

            float tOrigin[3]; GetClientAbsOrigin(target, tOrigin);
            float dist2 = GetVectorDistanceSquared(vEye, tOrigin);
            float maxDist = GetConVarFloat(gCvar_DistanceCull);
            if (dist2 > maxDist * maxDist) continue;

            float toTarget[3] = { tOrigin[0]-vEye[0], tOrigin[1]-vEye[1], tOrigin[2]-vEye[2] };
            NormalizeVector(toTarget);
            float dot = DotProduct(vForward, toTarget);
            if (dot < GetConVarFloat(gCvar_FOVCull)) continue;

            if (gCachedVisibility[viewer][target] > now)
            {
                MarkTeamSpotted(vTeam, target, now, GetConVarFloat(gCvar_SpotExpiry));
                localChecks++; checksDone++;
                continue;
            }

            bool visible = false;
            int samples = (GetConVarInt(gCvar_MaxLosSamples) < 6) ? GetConVarInt(gCvar_MaxLosSamples) : 6;
            float sample[3];

            for (int s = 0; s < samples; s++)
            {
                GetTargetSamplePosition(target, s, sample);
                if (DoTraceLine(vEye, sample, viewer, target))
                {
                    visible = true;
                    break;
                }
            }

            if (visible)
            {
                gCachedVisibility[viewer][target] = now + GetConVarFloat(gCvar_SpotExpiry);
                MarkTeamSpotted(vTeam, target, now, GetConVarFloat(gCvar_SpotExpiry));
            }
            else
            {
                gCachedVisibility[viewer][target] = 0.0;
            }

            localChecks++; checksDone++;
        }
    }

    return Plugin_Continue;
}

/* === Broadcast spotted messages === */
public Action Timer_Broadcast(Handle timer)
{
    if (GetConVarInt(gCvar_Enabled) == 0) return Plugin_Continue;
    float now = GetEngineTime();

    Handle iter = CreateTrieIterator(gTeamSpotted);
    char key[16];
    while (TrieIteratorNext(iter, key, sizeof(key)))
    {
        Handle arr = TrieGetHandle(gTeamSpotted, key);
        if (arr == INVALID_HANDLE) continue;

        int team = StringToInt(key);
        int len = GetArraySize(arr);
        if (len == 0) continue;

        for (int i = 1; i <= MaxClients; i++)
        {
            if (!IsClientInGame(i) || GetClientTeam(i) != team) continue;

            StartMessage("pvs_spotted", i);
            BfWriteFloat(GetUserMessage(), now);
            BfWriteByte(GetUserMessage(), len);
            for (int idx = 0; idx < len; idx += 3)
            {
                WriteShort(GetArrayCell(arr, idx));
                BfWriteFloat(GetUserMessage(), CellToFloat(GetArrayCell(arr, idx+1)));
                WriteShort(GetArrayCell(arr, idx+2));
            }
            EndMessage();
        }
    }
    CloseHandle(iter);

    ExpireTeamSpots(now);
    return Plugin_Continue;
}

/* === Helpers === */
void GetClientForwardVector(int client, float out[3])
{
    float ang[3]; GetClientEyeAngles(client, ang);
    float pitch = ang[0] * (M_PI / 180.0);
    float yaw   = ang[1] * (M_PI / 180.0);
    out[0] = Cos(pitch) * Cos(yaw);
    out[1] = Cos(pitch) * Sin(yaw);
    out[2] = -Sin(pitch);
    NormalizeVector(out); // use SDKTools NormalizeVector
}

float GetVectorDistanceSquared(float a[3], float b[3])
{
    float dx = a[0]-b[0], dy = a[1]-b[1], dz = a[2]-b[2];
    return dx*dx + dy*dy + dz*dz;
}

float DotProduct(const float a[3], const float b[3])
{
    return a[0]*b[0] + a[1]*b[1] + a[2]*b[2];
}

// … rest of the helpers (GetTargetSamplePosition, DoTraceLine, MarkTeamSpotted, ExpireTeamSpots, RemovePlayerFromAllTeamSpots, Event_PlayerDeath, Event_PlayerDisconnect) remain unchanged, just ensure they use FloatToCell/CellToFloat from <sdktools> and NormalizeVector from <sdktools>
/* === Helpers: target samples, traces, team marking === */
void GetTargetSamplePosition(int target, int sampleIndex, float out[3])
{
    SDKTools_GetClientEyePosition(target, out); // head
    if (sampleIndex == 0) return;

    GetClientAbsOrigin(target, out); // origin
    if (sampleIndex == 1) { out[2] += 40.0; return; } // chest
    if (sampleIndex == 2) { out[2] += 10.0; return; } // hips/legs
    if (sampleIndex == 3) { out[0] += 12.0; out[1] += 0.0; out[2] += 20.0; return; }
    if (sampleIndex == 4) { out[0] -= 12.0; out[1] += 0.0; out[2] += 20.0; return; }
    if (sampleIndex == 5) { out[0] += 0.0; out[1] += 12.0; out[2] += 20.0; return; }
}

bool DoTraceLine(float start[3], float end[3], int viewer, int expectedTarget)
{
    Handle tr = TR_TraceRayFilterEx(start, end, MASK_SOLID, RayType_EndPoint, TraceFilter, viewer);
    bool hit = TR_DidHit(tr);
    int ent = TR_GetEntityIndex(tr);
    CloseHandle(tr);
    return !hit || ent == expectedTarget;
}

public bool TraceFilter(int entIndex, int contentsMask, any data)
{
    int viewer = data;
    return entIndex != viewer;
}

public void MarkTeamSpotted(int team, int enemy, float now, float expiryDuration)
{
    if (team <= 0) return;
    char key[16]; IntToString(team, key, sizeof(key));
    Handle arr = TrieGetHandle(gTeamSpotted, key);
    if (arr == INVALID_HANDLE)
    {
        arr = CreateArray(3); // triples: enemyId, expiry, zone
        TrieSetHandle(gTeamSpotted, key, arr);
    }

    int len = GetArraySize(arr);
    for (int i = 0; i < len; i += 3)
    {
        int storedId = GetArrayCell(arr, i);
        if (storedId == enemy)
        {
            SetArrayCell(arr, i+1, FloatToCell(now + expiryDuration));
            return;
        }
    }

    // Push new triple
    PushArrayCell(arr, enemy);
    PushArrayCell(arr, FloatToCell(now + expiryDuration));
    PushArrayCell(arr, 0); // zone=0
}

public void ExpireTeamSpots(float now)
{
    Handle iter = CreateTrieIterator(gTeamSpotted);
    char key[16];
    while (TrieIteratorNext(iter, key, sizeof(key)))
    {
        Handle arr = TrieGetHandle(gTeamSpotted, key);
        if (arr == INVALID_HANDLE) continue;

        int len = GetArraySize(arr);
        for (int i = len - 3; i >= 0; i -= 3)
        {
            float expiry = CellToFloat(GetArrayCell(arr, i+1));
            if (expiry < now)
            {
                RemoveArrayCell(arr, i+2);
                RemoveArrayCell(arr, i+1);
                RemoveArrayCell(arr, i+0);
            }
        }
    }
    CloseHandle(iter);
}

public void RemovePlayerFromAllTeamSpots(int player)
{
    Handle iter = CreateTrieIterator(gTeamSpotted);
    char key[16];
    while (TrieIteratorNext(iter, key, sizeof(key)))
    {
        Handle arr = TrieGetHandle(gTeamSpotted, key);
        if (arr == INVALID_HANDLE) continue;

        int len = GetArraySize(arr);
        for (int i = len - 3; i >= 0; i -= 3)
        {
            int storedId = GetArrayCell(arr, i);
            if (storedId == player)
            {
                RemoveArrayCell(arr, i+2);
                RemoveArrayCell(arr, i+1);
                RemoveArrayCell(arr, i+0);
            }
        }
    }
    CloseHandle(iter);
}

/* === Player Events === */
public void Event_PlayerDeath(Event event, const char[] name, bool dontbroadcast)
{
    int userid = event.GetInt("userid");
    int client = GetClientOfUserId(userid);
    RemovePlayerFromAllTeamSpots(client);

    for (int v = 1; v <= MaxClients; v++)
    {
        gCachedVisibility[v][client] = 0.0;
        gCachedVisibility[client][v] = 0.0;
    }
}

public void Event_PlayerDisconnect(Event event, const char[] name, bool dontbroadcast)
{
    int userid = event.GetInt("userid");
    int client = GetClientOfUserId(userid);
    RemovePlayerFromAllTeamSpots(client);

    for (int v = 1; v <= MaxClients; v++)
    {
        gCachedVisibility[v][client] = 0.0;
        gCachedVisibility[client][v] = 0.0;
    }
}
