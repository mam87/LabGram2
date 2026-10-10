// In-memory mock of the parts of supabase-js used by LabGram (test only)
(function(){
  const uid=()=>crypto.randomUUID();
  const now=(m=0)=>new Date(Date.now()-m*60000).toISOString();
  const me='11111111-1111-1111-1111-111111111111', u2='22222222-2222-2222-2222-222222222222', u3='33333333-3333-3333-3333-333333333333';
  const img='data:image/svg+xml,'+encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="800" height="600"><defs><radialGradient id="g"><stop offset="0" stop-color="#f0abfc"/><stop offset="1" stop-color="#7c3aed"/></radialGradient></defs><rect width="800" height="600" fill="#fdf2f8"/><g fill="url(#g)" opacity=".85"><circle cx="200" cy="200" r="80"/><circle cx="420" cy="320" r="100"/><circle cx="620" cy="160" r="70"/><circle cx="560" cy="460" r="60"/></g><g fill="#4c1d95"><circle cx="190" cy="190" r="30"/><circle cx="410" cy="310" r="38"/><circle cx="615" cy="150" r="26"/><circle cx="555" cy="455" r="22"/></g></svg>');
  const p1=uid(),p2=uid(),p3=uid();
  const DB={
    lg_profiles:[
      {id:me,username:'mam87',display_name:'أنس السعودي',specialty:'Histopathology',bio:'مشرف مختبر الأنسجة والخلايا · ISO 15189',avatar_url:null,cover:'aurora',role:'owner',verified:false,banned:false,created_at:now(500)},
      {id:u2,username:'sara_lab',display_name:'سارة أحمد',specialty:'Microbiology',bio:'',avatar_url:null,cover:'sunset',role:'user',verified:true,banned:false,created_at:now(300)},
      {id:u3,username:'omar.hema',display_name:'عمر خالد',specialty:'Hematology',bio:'',avatar_url:null,cover:'ocean',role:'user',verified:false,banned:true,created_at:now(200)},
    ],
    lg_posts:[
      {id:p1,user_id:u2,body:'صورة جميلة لصبغة غرام اليوم 🦠\nلاحظوا التمييز الواضح بين الموجبة والسالبة.',image_url:img,category:'Microbiology',pinned:false,created_at:now(30)},
      {id:p2,user_id:me,body:'تذكير: مراجعة نتائج IQC يومياً قبل إصدار أي نتيجة. قواعد Westgard ليست خياراً!',image_url:null,category:'Laboratory Quality',pinned:true,created_at:now(120)},
      {id:p3,user_id:u3,body:'',image_url:img,category:'Hematology',pinned:false,created_at:now(600)},
    ],
    lg_likes:[{post_id:p1,user_id:me},{post_id:p1,user_id:u3},{post_id:p2,user_id:u2}],
    lg_comments:[{id:'c0000000-0000-0000-0000-000000000001',post_id:p1,user_id:u3,body:'رائع جداً 👏',parent_id:null,created_at:now(20)},
                 {id:'c0000000-0000-0000-0000-000000000002',post_id:p1,user_id:u2,body:'شكراً عمر!',parent_id:'c0000000-0000-0000-0000-000000000001',created_at:now(18)}],
    lg_follows:[{follower_id:me,following_id:u2}],
    lg_saves:[{user_id:me,post_id:p3,created_at:now(5)}],
    lg_reports:[{id:uid(),post_id:p1,reporter_id:u3,reason:'يحتوي بيانات تعريفية لمريض',status:'open',created_at:now(15)}],
    lg_notifications:[{id:uid(),user_id:me,actor_id:u3,type:'comment',post_id:p1,comment_id:'c0000000-0000-0000-0000-000000000002',read:false,created_at:now(10)},{id:uid(),user_id:me,actor_id:u2,type:'like',post_id:p2,read:false,created_at:now(100)},{id:uid(),user_id:me,actor_id:u3,type:'follow',post_id:null,read:true,created_at:now(400)}],
  };
  const QS=new URLSearchParams(location.search);
  if(QS.has('empty')){ for(const k of ['lg_posts','lg_likes','lg_comments','lg_follows','lg_notifications','lg_reports','lg_saves']) DB[k]=[]; DB.lg_profiles=DB.lg_profiles.slice(0,1); }
  window.__DB=DB; window.__UPLOADS=[]; window.__CALLS=[]; let authCb=null;
  const SIGNED = location.search.includes('signed');
  const session = SIGNED?{user:{id:me,user_metadata:{}}}:null;

  function parseSelect(s){
    const out=[]; let depth=0,cur='';
    for(const ch of s){ if(ch==='(')depth++; if(ch===')')depth--; if(ch===','&&!depth){out.push(cur.trim());cur='';} else cur+=ch; }
    if(cur.trim()) out.push(cur.trim());
    return out.map(f=>{
      const m=f.match(/^(?:(\w+):)?(\w+)(?:!(\w+))?\((.*)\)$/);
      if(!m) return {col:f};
      return {alias:m[1]||m[2],table:m[2],fk:m[3],inner:m[4]};
    });
  }
  function shape(table,row,fields){
    const o={...row};
    for(const f of fields){
      if(!f.table) continue;
      if(f.fk){
        const col=f.fk.replace(table+'_','').replace('_fkey','');
        const t=DB[f.table].find(r=>r.id===row[col]);
        o[f.alias]=t?shape(f.table,t,parseSelect(f.inner)):null;
      } else if(f.table==='lg_posts' && row.post_id){
        const t=DB.lg_posts.find(r=>r.id===row.post_id);
        o[f.alias]=t?shape('lg_posts',t,parseSelect(f.inner)):null;
      } else {
        const kids=DB[f.table].filter(r=>r.post_id===row.id);
        o[f.alias]= f.inner==='count' ? [{count:kids.length}] : kids.map(k=>({...k}));
      }
    }
    return o;
  }
  function Q(table){
    const st={table,filters:[],op:'select',fields:[],order:null,range:null,limit:null,single:null,head:false,count:null};
    const api={
      select(s='*',opt={}){ if(st.op==='select'||st.op==='selectOnly'){st.op='select'} st.ret=true; st.fields=parseSelect(s); st.head=!!opt.head; st.count=opt.count; return api },
      gte(c,v){st.filters.push(r=>r[c]>=v);return api}, eq(c,v){st.filters.push(r=>r[c]===v);return api}, neq(c,v){st.filters.push(r=>r[c]!==v);return api},
      gte(c,v){st.filters.push(r=>r[c]>=v);return api},
      in(c,v){st.filters.push(r=>v.includes(r[c]));return api},
      not(c,op,v){st.filters.push(r=>r[c]!==null&&r[c]!==undefined);return api},
      or(){return api}, ilike(){return api},
      order(c,o={}){st.order=[c,o.ascending!==false];return api},
      range(a,b){st.range=[a,b];return api}, limit(n){st.limit=n;return api},
      maybeSingle(){st.single='maybe';return api}, single(){st.single='one';return api},
      insert(v){st.op='insert';st.val=v;return api}, update(v){st.op='update';st.val=v;return api}, delete(){st.op='delete';return api},
      then(res,rej){return Promise.resolve(run()).then(res,rej)},
    };
    function run(){
      window.__CALLS.push(table+':'+st.op);
      if(QS.get('err')===table) return {data:null,error:{message:'simulated network failure',code:'XX000'}};
      if(QS.has('setup')) return {data:null,error:{message:'Could not find the table public.'+table+' in the schema cache',code:'PGRST205'}};
      const T=DB[table]; let rows;
      if(st.op==='insert'){
        const r={id:uid(),created_at:now(),read:false,pinned:false,...st.val}; T.push(r); rows=[r];
        if(table==='lg_profiles'){}
      } else {
        rows=T.filter(r=>st.filters.every(f=>f(r)));
        if(st.op==='update'){rows.forEach(r=>{
          if(table==='lg_posts' && ['body','category','image_url'].some(k=>k in st.val && st.val[k]!==r[k])) r.edited_at=now();
          Object.assign(r,st.val)})}
        if(st.op==='delete'){DB[table]=T.filter(r=>!rows.includes(r));return {data:null,error:null}}
        if(st.op==='update'&&!st.ret) return {data:null,error:null};
      }
      if(st.head) return {data:null,count:rows.length,error:null};
      if(st.order){const [c,asc]=st.order;rows=[...rows].sort((a,b)=>(a[c]>b[c]?1:-1)*(asc?1:-1))}
      if(st.range) rows=rows.slice(st.range[0],st.range[1]+1);
      if(st.limit) rows=rows.slice(0,st.limit);
      rows=rows.map(r=>shape(table,r,st.fields));
      if(st.single) return {data:rows[0]||null,error:null};
      return {data:rows,error:null};
    }
    return api;
  }
  window.supabase={createClient(){return {
    from:Q, rpc:async(name,args)=>name==='lg_username_available'?{data:!DB.lg_profiles.some(x=>x.username.toLowerCase()===String(args.u).toLowerCase()),error:null}:({data:DB.lg_profiles.map(p=>({id:p.id,email:p.username+'@example.com',last_sign_in_at:now(5),confirmed:true})),error:null}),
    auth:{
      getSession:async()=>({data:{session}}),
      onAuthStateChange(cb){authCb=cb;return {data:{subscription:{unsubscribe(){}}}}},
      signInWithPassword:async()=>({error:{message:'Invalid login credentials'}}),
      signUp:async()=>({data:{session:null},error:null}),
      signOut:async()=>{ setTimeout(()=>authCb&&authCb('SIGNED_OUT',null),0); return {} }, resetPasswordForEmail:async()=>({}), updateUser:async(x)=>{window.__PW=x;return {data:{},error:null}},
    },
    storage:{from(){return {upload:async(path,f)=>{window.__UPLOADS.push({path,type:f.type,size:f.size});return {error:null}},getPublicUrl:p=>({data:{publicUrl:img}}),remove:async()=>({})}}},
  }}};
})();
