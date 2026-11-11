import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const cors={"Access-Control-Allow-Origin":Deno.env.get("APP_ORIGIN")??"*","Access-Control-Allow-Headers":"authorization, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS"};
Deno.serve(async(req)=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
 if(req.method!=="POST")return Response.json({error:"Method not allowed"},{status:405,headers:cors});
 try{
  const auth=req.headers.get("Authorization");if(!auth?.startsWith("Bearer "))return Response.json({error:"Authentication required"},{status:401,headers:cors});
  const client=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_ANON_KEY")!,{global:{headers:{Authorization:auth}},auth:{persistSession:false,autoRefreshToken:false}});
  const {data:{user},error:authError}=await client.auth.getUser();if(authError||!user)return Response.json({error:"Invalid session"},{status:401,headers:cors});
  const b=await req.json();if(!b.restaurant_id||!b.qr_token||!Array.isArray(b.items)||!b.items.length||!b.idempotency_key||!["cash","online"].includes(b.payment_method))return Response.json({error:"Invalid order request"},{status:400,headers:cors});
  const {data,error}=await client.rpc("place_table_order",{p_restaurant_id:b.restaurant_id,p_qr_token:b.qr_token,p_items:b.items,p_payment_method:b.payment_method,p_instructions:b.instructions??null,p_idempotency_key:b.idempotency_key});
  if(error)return Response.json({error:error.message},{status:400,headers:cors});
  return Response.json(data,{headers:cors});
 }catch(e){console.error(e);return Response.json({error:"Unable to process order"},{status:500,headers:cors});}
});
