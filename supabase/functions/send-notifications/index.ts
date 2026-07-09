import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

type QueueItem = {
  id: string;
  employee_id: string | null;
  branch_num: number | null;
  title: string;
  body: string;
  data: Record<string, unknown>;
};

type DeviceToken = {
  id: string;
  employee_id: string;
  token: string;
};

type Employee = {
  id: string;
  branch_num: number | null;
  role: string | null;
  can_manage_all_branches: boolean | null;
};

const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const firebaseJson = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_JSON") ?? "";

serve(async () => {
  if (!supabaseUrl || !serviceRoleKey || !firebaseJson) {
    return json({ ok: false, error: "Missing required secrets" }, 500);
  }

  const accessToken = await getFirebaseAccessToken();
  const queue = await supabaseGet<QueueItem[]>(
    "/rest/v1/ansar_notification_queue?status=eq.pending&select=id,employee_id,branch_num,title,body,data&order=created_at.asc&limit=25",
  );

  let sent = 0;
  let failed = 0;

  for (const item of queue) {
    try {
      const tokens = await getTargetTokens(item);
      const uniqueTokens = dedupeByToken(tokens);
      if (uniqueTokens.length === 0) {
        throw new Error("No active device tokens matched this notification");
      }
      const results = await Promise.allSettled(
        uniqueTokens.map((device) => sendToDevice(accessToken, item, device)),
      );

      for (let i = 0; i < results.length; i++) {
        const result = results[i];
        if (result.status === "rejected" && String(result.reason).includes("UNREGISTERED")) {
          await deactivateToken(uniqueTokens[i].id);
        }
      }

      const rejected = results.filter((result) => result.status === "rejected");
      if (rejected.length > 0 && rejected.length === results.length && results.length > 0) {
        const allUnregistered = rejected.every((result) => String(result.reason).includes("UNREGISTERED"));
        if (!allUnregistered) {
          throw new Error(String(rejected[0].reason));
        }
      }

      await markQueueItem(item.id, "sent");
      sent += 1;
    } catch (error) {
      await markQueueItem(item.id, "failed", String(error));
      failed += 1;
    }
  }

  return json({ ok: true, processed: queue.length, sent, failed });
});

async function getTargetTokens(item: QueueItem): Promise<DeviceToken[]> {
  const senderId =
    typeof item.data?.sender_id === "string"
      ? item.data.sender_id
      : typeof item.data?.employee_id === "string"
        ? item.data.employee_id
        : null;

  if (item.employee_id) {
    return (await loadTokens()).filter((token) => token.employee_id === item.employee_id && token.employee_id !== senderId);
  }

  if (item.branch_num !== null && item.branch_num !== undefined) {
    const [tokens, employees] = await Promise.all([loadTokens(), loadEmployees()]);
    const allowedEmployeeIds = new Set(
      employees
        .filter((employee) =>
          employee.branch_num === item.branch_num ||
          employee.role === "admin" ||
          employee.can_manage_all_branches === true
        )
        .map((employee) => employee.id),
    );
    if (senderId) allowedEmployeeIds.delete(senderId);
    return tokens.filter((token) => allowedEmployeeIds.has(token.employee_id));
  }

  return (await loadTokens()).filter((token) => token.employee_id !== senderId);
}

async function loadTokens(): Promise<DeviceToken[]> {
  return await supabaseGet<DeviceToken[]>(
    "/rest/v1/ansar_device_tokens?is_active=eq.true&select=id,employee_id,token",
  );
}

async function loadEmployees(): Promise<Employee[]> {
  return await supabaseGet<Employee[]>(
    "/rest/v1/ansar_employees?is_active=eq.true&select=id,branch_num,role,can_manage_all_branches",
  );
}

async function sendToDevice(accessToken: string, item: QueueItem, device: DeviceToken) {
  const serviceAccount = JSON.parse(firebaseJson);
  const projectId = serviceAccount.project_id;
  const response = await fetch(`https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      message: {
        token: device.token,
        notification: {
          title: item.title,
          body: item.body,
        },
        data: stringifyData(item.data),
        android: {
          priority: "HIGH",
          notification: {
            sound: "default",
          },
        },
      },
    }),
  });

  if (!response.ok) {
    throw new Error(await response.text());
  }
}

async function getFirebaseAccessToken(): Promise<string> {
  const serviceAccount = JSON.parse(firebaseJson);
  const now = Math.floor(Date.now() / 1000);
  const assertion = await signJwt(
    serviceAccount.client_email,
    serviceAccount.private_key,
    {
      scope: "https://www.googleapis.com/auth/firebase.messaging",
      aud: "https://oauth2.googleapis.com/token",
      iat: now,
      exp: now + 3600,
    },
  );

  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });

  if (!response.ok) {
    throw new Error(await response.text());
  }

  const payload = await response.json();
  return payload.access_token;
}

async function signJwt(clientEmail: string, privateKey: string, claims: Record<string, unknown>) {
  const header = base64Url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const payload = base64Url(JSON.stringify({ iss: clientEmail, ...claims }));
  const unsignedToken = `${header}.${payload}`;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToArrayBuffer(privateKey),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(unsignedToken),
  );
  return `${unsignedToken}.${base64Url(new Uint8Array(signature))}`;
}

function pemToArrayBuffer(pem: string) {
  const normalized = pem.replace(/\\n/g, "\n");
  const b64 = normalized
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s/g, "");
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes.buffer;
}

function base64Url(value: string | Uint8Array) {
  const bytes = typeof value === "string" ? new TextEncoder().encode(value) : value;
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function stringifyData(data: Record<string, unknown>) {
  const output: Record<string, string> = {};
  for (const [key, value] of Object.entries(data ?? {})) {
    if (value !== null && value !== undefined) output[key] = String(value);
  }
  return output;
}

function dedupeByToken(tokens: DeviceToken[]) {
  const seen = new Set<string>();
  return tokens.filter((device) => {
    if (seen.has(device.token)) return false;
    seen.add(device.token);
    return true;
  });
}

async function deactivateToken(id: string) {
  await supabasePatch(`/rest/v1/ansar_device_tokens?id=eq.${id}`, { is_active: false });
}

async function markQueueItem(id: string, status: "sent" | "failed", error?: string) {
  await supabasePatch(`/rest/v1/ansar_notification_queue?id=eq.${id}`, {
    status,
    sent_at: status === "sent" ? new Date().toISOString() : null,
    error_message: error?.slice(0, 800) ?? null,
  });
}

async function supabaseGet<T>(path: string): Promise<T> {
  const response = await fetch(`${supabaseUrl}${path}`, {
    headers: {
      apikey: serviceRoleKey,
      Authorization: `Bearer ${serviceRoleKey}`,
    },
  });
  if (!response.ok) throw new Error(await response.text());
  return await response.json();
}

async function supabasePatch(path: string, body: Record<string, unknown>) {
  const response = await fetch(`${supabaseUrl}${path}`, {
    method: "PATCH",
    headers: {
      apikey: serviceRoleKey,
      Authorization: `Bearer ${serviceRoleKey}`,
      "Content-Type": "application/json",
      Prefer: "return=minimal",
    },
    body: JSON.stringify(body),
  });
  if (!response.ok) throw new Error(await response.text());
}

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
