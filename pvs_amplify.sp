/**
 * pvs_amplify.sp
 * SourceMod 1.10 (CS2) — tight server-side LOS-based spotting
 *
 * Features:
 * - Distance and FOV pre-filters
 * - Multi-sample LOS checks
 * - Staggered checks + caching
 * - Team aggregation + compact broadcast
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

/* == Internal storage == */
#define MAXPLAYERS_SM 130
new Float:gCachedVisibility[MAXPLAYERS_SM][MAXPLAYERS_SM]; // default 0.0
new Handle:gTeamSpotted; // Trie: key=team string -> Handle to ArrayList of triples

new gServerTick = 0; // tick counter for staggering

/* Plugin startup */
public void OnPluginStart()
{
    gCvar_Enabled           = CreateConVar("pvsamp_enabled", "1", "Enable/disable PVS-Amplified spotting", 0, true, 0.0, true, 1.0);
    gCvar_CheckInterval     = CreateConVar("pvsamp_check_interval", "0.08", "Server tick interval to run checks (s)", 0, true, 0.01, true, 1.0);
    gCvar_BroadcastInterval = CreateConVar("pvsamp_broadcast_interval", "0.20", "How often to broadcast spotted updates (s)", 0, true, 0.05, true, 2.0);
    gCvar_MaxLosSamples     = CreateConVar("pvsamp_max_los_samples", "4", "Max LOS samples per target", 0, true, 1.0, true, 8.0);
    gCvar_MaxChecksPerTick  = CreateConVar("pvsamp_max_checks_per_tick", "512", "Max viewer->target checks per tick", 0, true, 16.0, true, 8192.0);
    gCvar_SpotExpiry        = CreateConVar("pvsamp_spot_expiry", "3.0", "Seconds before a spot expires", 0, true, 0.5, true, 30.0);
    gCvar_DistanceCull      = CreateConVar("pvsamp_distance_cull", "1500.0", "Max distance (units) to consider LOS", 0, true, 200.0, true, 5000.0);
    gCvar_FOVCull           = CreateConVar("pvsamp_fov_cos", "0.5", "Dot-product threshold for FOV cull (cos)", 0, true, -1.0, true, 1.0);

    CreateTimer(GetConVarFloat(gCvar_CheckInterval), Timer_CheckLOS, _, TIMER_REPEAT);
    CreateTimer(GetConVarFloat(gCvar_BroadcastInterval), Timer_Broadcast, _, TIMER_REPEAT);

    HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Post);
    HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);
}

/* === LOS Check Timer === */
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

    int viewerStart = gServerTick % ((vcount==0)?1:vcount);
    int candStart   = gServerTick % ((ccount==0)?1:ccount);

    for (int vi = 0; vi < vcount && checksDone < maxChecks; vi++)
    {
        int vIndex = (viewerStart + vi) % vcount;
        int viewer = viewers[vIndex];
        if (IsClientObserver(viewer)) continue;

        float vEye[3]; SDKTools_GetClientEyePosition(viewer, vEye);
        float vForward[3]; GetClientForwardVector(viewer, vForward);

        int vTeam = GetClientTeam(viewer);
        int perViewerCap = (maxChecks / ((vcount>0)?vcount:1));
        if (perViewerCap < 1) perViewerCap = 1;
        int localChecks = 0;

        for (int ci = 0; ci < ccount && localChecks < perViewerCap && checksDone < maxChecks; ci++)
        {
            int tIndex = (candStart + ci) % ccount;
            int target = candidates[tIndex];
            if (target == viewer || GetClientTeam(target) == vTeam) continue;

            float tOrigin[3]; SDKTools_GetClientAbsOrigin(target, tOrigin);
            float dist2 = GetVectorDistanceSquared(vEye, tOrigin);
            float maxDist = GetConVarFloat(gCvar_DistanceCull);
            if (dist2 > (maxDist*maxDist)) continue;

            float toTarget[3];
            toTarget[0] = tOrigin[0]-vEye[0];
            toTarget[1] = tOrigin[1]-vEye[1];
            toTarget[2] = tOrigin[2]-vEye[2];
            SDKTools_NormalizeVector(toTarget);

            float dot = DotProduct(vForward, toTarget);
            float fovThresh = GetConVarFloat(gCvar_FOVCull);
            if (dot < fovThresh) continue;

            if (gCachedVisibility[viewer][target] > now)
            {
                MarkTeamSpotted(vTeam, target, now, GetConVarFloat(gCvar_SpotExpiry));
                localChecks++; checksDone++;
                continue;
            }

            bool visible = false;
            int samples = GetConVarInt(gCvar_MaxLosSamples);
            if (samples > 6) samples = 6;

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

/* === Broadcast Timer === */
public Action Timer_Broadcast(Handle timer)
{
    if (GetConVarInt(gCvar_Enabled)==0) return Plugin_Continue;
    float now = GetEngineTime();

    Handle iter = CreateTrieIterator(gTeamSpotted);
    char key[16];

    while (TrieIteratorNext(iter, key, sizeof(key)))
    {
        Handle arr = TrieGetHandle(gTeamSpotted, key);
        if (arr == INVALID_HANDLE) continue;

        int team = StringToInt(key);
        int len = GetArraySize(arr)/3;

        for (int i=1; i<=MaxClients; i++)
        {
            if (!IsClientInGame(i) || GetClientTeam(i)!=team) continue;

            StartMessage("pvs_spotted", i);
            BfWriteFloat(GetUserMessage(), now);
            BfWriteByte(GetUserMessage(), len);

            for (int idx=0; idx<len*3; idx+=3)
            {
                BfWriteShort(GetUserMessage(), GetArrayCell(arr, idx));
                BfWriteFloat(GetUserMessage(), GetArrayCell(arr, idx+1));
                BfWriteShort(GetUserMessage(), GetArrayCell(arr, idx+2));
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
    float ang[3];
    GetClientEyeAngles(client, ang);

    float pitch = ang[0]*3.14159265/180.0;
    float yaw   = ang[1]*3.14159265/180.0;

    out[0] = Cos(pitch)*Cos(yaw);
    out[1] = Cos(pitch)*Sin(yaw);
    out[2] = -Sin(pitch);

    SDKTools_NormalizeVector(out);
}

float GetVectorDistanceSquared(float a[3], float b[3])
{
    float dx = a[0]-b[0];
    float dy = a[1]-b[1];
    float dz = a[2]-b[2];
    return dx*dx + dy*dy + dz*dz;
}

bool DoTraceLine(float start[3], float end[3], int viewer, int target)
{
    Handle tr = TR_TraceRayFilterEx(start, end, MASK_SOLID, RayType_EndPoint, TraceFilter, viewer);
    bool hit = TR_DidHit(tr);
    int ent = TR_GetEntityIndex(tr);
    CloseHandle(tr);

    return !(hit && ent != target);
}

public bool TraceFilter(int entIndex, int contentsMask, any data)
{
    int viewer = data;
    return (entIndex != viewer);
}

void GetTargetSamplePosition(int target, int sampleIndex, float out[3])
{
    SDKTools_GetClientEyePosition(target, out);
    if (sampleIndex==0) return;

    SDKTools_GetClientAbsOrigin(target, out);
    if (sampleIndex==1) { out[2]+=40.0; return; }
    if (sampleIndex==2) { out[2]+=10.0; return; }
    if (sampleIndex==3) { out[0]+=12.0; out[2]+=20.0; return; }
    if (sampleIndex==4) { out[0]-=12.0; out[2]+=20.0; return; }
    if (sampleIndex==5) { out[1]+=12.0; out[2]+=20.0; return; }
}

/* === Spot Storage === */
void MarkTeamSpotted(int team, int enemy, float now, float expiryDuration)
{
    if (team<=0) return;

    char key[16];
    IntToString(team, key, sizeof(key));

    Handle arr = TrieGetHandle(gTeamSpotted, key);
    if (arr==INVALID_HANDLE) { arr=CreateArray(3); TrieSetHandle(gTeamSpotted,key,arr); }

    int len = GetArraySize(arr);
    for (int i=0; i<len; i+=3)
    {
        if (GetArrayCell(arr,i)==enemy)
        {
            SetArrayCell(arr,i+1, RoundToCell(now+expiryDuration));
            return;
        }
    }

    PushArrayCell(arr, enemy);
    PushArrayCell(arr, RoundToCell(now+expiryDuration));
    PushArrayCell(arr, 0);
}

void ExpireTeamSpots(float now)
{
    Handle iter = CreateTrieIterator(gTeamSpotted);
    char key[16];

    while (TrieIteratorNext(iter,key,sizeof(key)))
    {
        Handle arr = TrieGetHandle(gTeamSpotted,key);
        if (arr==INVALID_HANDLE) continue;

        int len = GetArraySize(arr);
        for (int i=len-3; i>=0; i-=3)
        {
            if (GetArrayCell(arr,i+1) < RoundToCell(now))
            {
                RemoveArrayCell(arr,i+2);
                RemoveArrayCell(arr,i+1);
                RemoveArrayCell(arr,i+0);
            }
        }
    }
    CloseHandle(iter);
}

void RemovePlayerFromAllTeamSpots(int player)
{
    Handle iter = CreateTrieIterator(gTeamSpotted);
    char key[16];

    while (TrieIteratorNext(iter,key,sizeof(key)))
    {
        Handle arr = TrieGetHandle(gTeamSpotted,key);
        if (arr==INVALID_HANDLE) continue;

        int len = GetArraySize(arr);
        for (int i=len-3; i>=0; i-=3)
        {
            if (GetArrayCell(arr,i)==player)
            {
                RemoveArrayCell(arr,i+2);
                RemoveArrayCell(arr,i+1);
                RemoveArrayCell(arr,i+0);
            }
        }
    }
    CloseHandle(iter);
}

/* === Events === */
public void Event_PlayerDeath(Event event, const char[] name, bool dontbroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    RemovePlayerFromAllTeamSpots(client);

    for (int v=1; v<=MaxClients; v++)
    {
        gCachedVisibility[v][client]=0.0;
        gCachedVisibility[client][v]=0.0;
    }
}

public void Event_PlayerDisconnect(Event event, const char[] name, bool dontbroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    RemovePlayerFromAllTeamSpots(client);

    for (int v=1; v<=MaxClients; v++)
    {
        gCachedVisibility[v][client]=0.0;
        gCachedVisibility[client][v]=0.0;
    }
}
