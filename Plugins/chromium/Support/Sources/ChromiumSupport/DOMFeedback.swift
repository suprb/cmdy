import Foundation

/// Cmdy's dependency-free live DOM feedback picker. It uses a closed shadow
/// root so page styles cannot alter the picker and emits structured context
/// through CEF's existing console bridge.
public enum DOMFeedback {
    public static func script(token: String) -> String {
        let source = #"""
    (() => {
      if (window.__cmdyFeedback && window.__cmdyFeedback.version === 3) {
        window.__cmdyFeedback.toggle();
        return {success:true, active:window.__cmdyFeedback.active};
      }
      if (window.__cmdyFeedback) {
        try { window.__cmdyFeedback.teardown(); } catch (_) {}
      }

      const state = {active:false, hovered:null, selected:null, selectedElements:[],
        selectionContext:null, anchorRect:null, pointer:null, dragging:false, outlines:[], marker:0,
        dragFrame:0,dragPoint:null};
      const host = document.createElement('div');
      host.id = '__cmdy-feedback-host';
      host.style.cssText = 'all:initial;position:fixed;inset:0;z-index:2147483647;pointer-events:none';
      document.documentElement.appendChild(host);
      const shadow = host.attachShadow({mode:'closed'});
      shadow.innerHTML = `
        <style>
          :host{all:initial}*{box-sizing:border-box;letter-spacing:0}
          #box{display:none;position:fixed;border:2px solid #7fc579;background:rgba(127,197,121,.08);pointer-events:none}
          #marquee{display:none;position:fixed;border:1px solid #7fc579;background:rgba(127,197,121,.14);pointer-events:none}
          .outline{position:fixed;border:2px solid #7fc579;background:rgba(127,197,121,.06);pointer-events:none}
          #tag{display:none;position:fixed;padding:3px 6px;background:#111418;color:#d8ded7;border:1px solid #7fc579;font:11px ui-monospace,SFMono-Regular,Menlo,monospace;white-space:nowrap;pointer-events:none}
          #hint{display:none;position:fixed;left:50%;top:14px;transform:translateX(-50%);padding:7px 10px;background:#111418;color:#c8cec7;border:1px solid #404640;font:12px ui-monospace,SFMono-Regular,Menlo,monospace;box-shadow:0 8px 28px rgba(0,0,0,.25)}
          #editor{display:none;position:fixed;width:min(420px,calc(100vw - 24px));background:#111418;color:#eef2ed;border:1px solid #5b655b;box-shadow:0 14px 44px rgba(0,0,0,.36);pointer-events:auto}
          #summary{padding:8px 10px 0;color:#98a198;font:11px ui-monospace,SFMono-Regular,Menlo,monospace;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
          textarea{display:block;width:100%;min-height:86px;resize:vertical;padding:8px 10px;border:0;outline:0;background:transparent;color:#eef2ed;font:13px ui-monospace,SFMono-Regular,Menlo,monospace;line-height:1.45}
          #actions{display:flex;align-items:center;justify-content:space-between;padding:7px 10px;border-top:1px solid #303630;color:#7f887f;font:11px ui-monospace,SFMono-Regular,Menlo,monospace}
          button{appearance:none;border:0;background:transparent;color:#9bd695;padding:0;font:inherit;cursor:pointer}
          .pin{position:fixed;display:grid;place-items:center;width:22px;height:22px;border-radius:50%;transform:translate(-50%,-50%);background:#7fc579;color:#0d120d;border:2px solid white;box-shadow:0 2px 10px rgba(0,0,0,.35);font:700 11px ui-monospace,SFMono-Regular,Menlo,monospace;pointer-events:none}
        </style>
        <div id="box"></div><div id="marquee"></div><div id="tag"></div><div id="hint">click an element or drag a region · esc cancel</div>
        <div id="editor"><div id="summary"></div><textarea aria-label="Feedback note" placeholder="What should change?" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false"></textarea>
        <div id="actions"><span>return send · shift+return newline · esc cancel</span><button>[ send ]</button></div></div>`;
      const box=shadow.querySelector('#box'), marquee=shadow.querySelector('#marquee');
      const tag=shadow.querySelector('#tag'), hint=shadow.querySelector('#hint');
      const editor=shadow.querySelector('#editor'), summary=shadow.querySelector('#summary');
      const input=shadow.querySelector('textarea'), send=shadow.querySelector('button');
      const clean=value=>String(value||'').replace(/\s+/g,' ').trim();
      const clipped=(value,n=500)=>clean(value).slice(0,n);
      const escapeCSS=value=>window.CSS&&CSS.escape?CSS.escape(value):String(value).replace(/[^a-zA-Z0-9_-]/g,'\\$&');
      const labelFor=el=>clipped(el.getAttribute('aria-label')||el.getAttribute('alt')||el.getAttribute('title')||el.innerText||el.textContent||el.value,160);
      const selectorFor=el=>{
        if(el.id){const s='#'+escapeCSS(el.id);try{if(document.querySelectorAll(s).length===1)return s}catch(_){}}
        for(const attr of ['data-testid','data-test','data-cy','name']){
          const value=el.getAttribute&&el.getAttribute(attr);if(!value)continue;
          const s=`${el.localName}[${attr}="${String(value).replace(/"/g,'\\"')}"]`;
          try{if(document.querySelectorAll(s).length===1)return s}catch(_){}
        }
        const parts=[];let node=el;
        while(node&&node.nodeType===1&&node!==document.documentElement){
          let part=node.localName;
          const classes=Array.from(node.classList||[]).filter(c=>c&&!c.startsWith('__cmdy')).slice(0,2);
          if(classes.length)part+='.'+classes.map(escapeCSS).join('.');
          const siblings=node.parentElement?Array.from(node.parentElement.children).filter(x=>x.localName===node.localName):[];
          if(siblings.length>1)part+=`:nth-of-type(${siblings.indexOf(node)+1})`;
          parts.unshift(part);const candidate=parts.join(' > ');
          try{if(document.querySelectorAll(candidate).length===1)return candidate}catch(_){}
          node=node.parentElement;
        }
        return parts.join(' > ');
      };
      const reactInfo=el=>{
        const result={components:[],source:null};let fiber=null;
        for(const key of Object.keys(el)){if(key.startsWith('__reactFiber$')||key.startsWith('__reactInternalInstance$')){fiber=el[key];break}}
        const seen=new Set();
        for(let n=fiber,depth=0;n&&depth<12;n=n.return,depth++){
          const type=n.elementType||n.type;const name=typeof type==='string'?type:type&&(type.displayName||type.name);
          if(name&&!seen.has(name)){seen.add(name);result.components.push(name)}
          const src=n._debugSource;if(!result.source&&src&&src.fileName)result.source={file:src.fileName,line:src.lineNumber||null,column:src.columnNumber||null};
        }
        return result;
      };
      const mirrorMetadata=()=>{
        const mirror=location.port==='3200'||/serve[- ]?sim/i.test(document.title)||!!document.querySelector('[data-device-udid],[data-simulator-udid]');
        if(!mirror)return null;
        const named=document.querySelector('[data-device-name],[data-device-udid],[data-simulator-udid]');
        return {kind:'sim-mirror',device:named&&(named.getAttribute('data-device-name')||named.getAttribute('aria-label'))||null,udid:named&&(named.getAttribute('data-device-udid')||named.getAttribute('data-simulator-udid'))||null};
      };
      const contextFor=el=>{
        const r=el.getBoundingClientRect(),css=getComputedStyle(el),react=reactInfo(el),mirror=mirrorMetadata();
        const rect={x:r.x,y:r.y,width:r.width,height:r.height,top:r.top,right:r.right,bottom:r.bottom,left:r.left};
        return {element:`<${el.localName}>`,tag:el.localName,label:labelFor(el),text:clipped(el.innerText||el.textContent||el.value),
          selector:selectorFor(el),elementPath:selectorFor(el),url:location.href,title:document.title,bounds:rect,
          documentBounds:{x:r.x+scrollX,y:r.y+scrollY,width:r.width,height:r.height},point:{x:r.x+r.width/2,y:r.y+r.height/2},
          viewport:{width:innerWidth,height:innerHeight,dpr:devicePixelRatio},cssClasses:Array.from(el.classList||[]).slice(0,20),
          computedStyles:{display:css.display,position:css.position,color:css.color,backgroundColor:css.backgroundColor,fontFamily:css.fontFamily,fontSize:css.fontSize,fontWeight:css.fontWeight,lineHeight:css.lineHeight,padding:css.padding,margin:css.margin,border:css.border},
          accessibility:{role:el.getAttribute('role')||null,name:el.getAttribute('aria-label')||labelFor(el)||null,description:el.getAttribute('aria-description')||el.getAttribute('title')||null,expanded:el.getAttribute('aria-expanded'),selected:el.getAttribute('aria-selected'),checked:el.getAttribute('aria-checked'),disabled:el.getAttribute('aria-disabled')||el.disabled||false},
          nearbyText:clipped(el.parentElement&&(el.parentElement.innerText||el.parentElement.textContent),700),selectedText:clipped(String(getSelection?getSelection():''),500),
          reactComponents:react.components,sourceLocation:react.source,mirror};
      };
      const compactContextFor=el=>{
        const r=el.getBoundingClientRect(),react=reactInfo(el),css=getComputedStyle(el);
        return {element:`<${el.localName}>`,tag:el.localName,label:labelFor(el),
          text:clipped(el.innerText||el.textContent||el.value,240),selector:selectorFor(el),
          bounds:{x:r.x,y:r.y,width:r.width,height:r.height,top:r.top,right:r.right,bottom:r.bottom,left:r.left},
          documentBounds:{x:r.x+scrollX,y:r.y+scrollY,width:r.width,height:r.height},
          accessibility:{role:el.getAttribute('role')||null,name:el.getAttribute('aria-label')||labelFor(el)||null,
            disabled:el.getAttribute('aria-disabled')||el.disabled||false},
          computedStyles:{display:css.display,position:css.position,color:css.color,
            backgroundColor:css.backgroundColor,fontSize:css.fontSize,fontWeight:css.fontWeight},
          reactComponents:react.components,sourceLocation:react.source};
      };
      const rectFromPoints=(a,b)=>({left:Math.min(a.x,b.x),top:Math.min(a.y,b.y),
        right:Math.max(a.x,b.x),bottom:Math.max(a.y,b.y),
        get x(){return this.left},get y(){return this.top},
        get width(){return this.right-this.left},get height(){return this.bottom-this.top}});
      const groupContextFor=(elements,r)=>{
        const mirror=mirrorMetadata(),items=elements.slice(0,80).map(compactContextFor);
        const bounds={x:r.left,y:r.top,width:r.width,height:r.height,top:r.top,right:r.right,bottom:r.bottom,left:r.left};
        return {selectionType:'region',element:`<region:${elements.length}>`,tag:'region',
          label:`${elements.length} elements`,text:clipped(items.map(item=>item.text||item.label).filter(Boolean).join(' · '),1400),
          selector:null,elementPath:null,url:location.href,title:document.title,bounds,
          documentBounds:{x:r.left+scrollX,y:r.top+scrollY,width:r.width,height:r.height},
          point:{x:r.left+r.width/2,y:r.top+r.height/2},viewport:{width:innerWidth,height:innerHeight,dpr:devicePixelRatio},
          elementCount:elements.length,elements:items,nearbyText:clipped(items.map(item=>item.text).filter(Boolean).join(' '),1800),
          selectedText:clipped(String(getSelection?getSelection():''),500),mirror};
      };
      const isOverlay=event=>event.composedPath&&event.composedPath().some(node=>node===host||node===shadow);
      const clearOutlines=()=>{for(const node of state.outlines)node.remove();state.outlines=[]};
      const cancelDragFrame=()=>{if(state.dragFrame)cancelAnimationFrame(state.dragFrame);state.dragFrame=0;state.dragPoint=null};
      const hideHighlight=()=>{box.style.display='none';marquee.style.display='none';tag.style.display='none';clearOutlines()};
      const draw=el=>{
        const r=el.getBoundingClientRect();
        Object.assign(box.style,{display:'block',left:r.left+'px',top:r.top+'px',width:Math.max(0,r.width)+'px',height:Math.max(0,r.height)+'px'});
        tag.textContent=`${el.localName}${el.id?'#'+el.id:''}${labelFor(el)?' · '+labelFor(el).slice(0,48):''}`;tag.style.display='block';
        tag.style.left=Math.max(4,Math.min(innerWidth-260,r.left))+'px';tag.style.top=(r.top>30?r.top-25:Math.min(innerHeight-24,r.bottom+4))+'px';
      };
      const drawMarquee=r=>{hideHighlight();Object.assign(marquee.style,{display:'block',left:r.left+'px',top:r.top+'px',width:r.width+'px',height:r.height+'px'})};
      const drawGroup=(elements,r)=>{
        hideHighlight();Object.assign(marquee.style,{display:'block',left:r.left+'px',top:r.top+'px',width:r.width+'px',height:r.height+'px'});
        for(const el of elements.slice(0,80)){
          const b=el.getBoundingClientRect(),outline=document.createElement('div');outline.className='outline';
          Object.assign(outline.style,{left:b.left+'px',top:b.top+'px',width:Math.max(0,b.width)+'px',height:Math.max(0,b.height)+'px'});
          shadow.appendChild(outline);state.outlines.push(outline);
        }
        tag.textContent=`${elements.length} element${elements.length===1?'':'s'} in region`;tag.style.display='block';
        tag.style.left=Math.max(4,Math.min(innerWidth-180,r.left))+'px';tag.style.top=(r.top>30?r.top-25:Math.min(innerHeight-24,r.bottom+4))+'px';
      };
      const stop=()=>{cancelDragFrame();state.active=false;state.hovered=null;state.selected=null;state.selectedElements=[];
        state.selectionContext=null;state.anchorRect=null;state.pointer=null;state.dragging=false;hideHighlight();
        hint.style.display='none';editor.style.display='none';input.value='';document.documentElement.style.removeProperty('cursor')};
      const start=()=>{cancelDragFrame();state.active=true;state.selected=null;state.selectedElements=[];state.selectionContext=null;
        state.anchorRect=null;state.pointer=null;state.dragging=false;editor.style.display='none';input.value='';
        hint.textContent='click an element or drag a region · esc cancel';hint.style.display='block';
        document.documentElement.style.setProperty('cursor','crosshair','important')};
      const positionEditor=r=>{editor.style.display='block';const width=Math.min(420,innerWidth-24),height=158;let left=Math.max(12,Math.min(innerWidth-width-12,r.left)),top=r.bottom+10;if(top+height>innerHeight-12)top=Math.max(12,r.top-height-10);editor.style.left=left+'px';editor.style.top=top+'px'};
      const choose=el=>{const r=el.getBoundingClientRect();state.selected=el;state.selectedElements=[el];
        state.selectionContext={...contextFor(el),selectionType:'element'};state.anchorRect=r;state.hovered=el;draw(el);
        hint.style.display='none';summary.textContent=`${selectorFor(el)}${labelFor(el)?' · '+labelFor(el):''}`;
        positionEditor(r);requestAnimationFrame(()=>input.focus())};
      const elementsInRegion=r=>{
        const ignored=new Set(['html','body','script','style','link','meta','head','noscript','template']);
        const hits=[];const all=document.querySelectorAll('body *');
        for(let i=0;i<all.length&&i<20000;i++){
          const el=all[i];if(el===host||ignored.has(el.localName))continue;
          const b=el.getBoundingClientRect();if(b.width<1||b.height<1||b.right<r.left||b.left>r.right||b.bottom<r.top||b.top>r.bottom)continue;
          const css=getComputedStyle(el);if(css.display==='none'||css.visibility==='hidden'||Number(css.opacity)===0)continue;
          hits.push(el);
        }
        const set=new Set(hits),interactive='a,button,input,select,textarea,summary,[role],[tabindex],img,video,canvas,svg';
        const meaningful=hits.filter(el=>el.matches(interactive)||!Array.from(el.children).some(child=>set.has(child)));
        return (meaningful.length?meaningful:hits).slice(0,80);
      };
      const chooseGroup=(elements,r)=>{state.selected=elements[0]||document.body;state.selectedElements=elements;
        state.selectionContext=groupContextFor(elements,r);state.anchorRect=r;state.hovered=null;drawGroup(elements,r);
        hint.style.display='none';summary.textContent=`region · ${elements.length} selected element${elements.length===1?'':'s'}`;
        positionEditor(r);requestAnimationFrame(()=>input.focus())};
      const previewGroup=point=>{
        if(!state.pointer||!state.dragging)return;
        const r=rectFromPoints(state.pointer,point),elements=elementsInRegion(r);
        state.selectedElements=elements;drawGroup(elements,r);
        hint.textContent=`${elements.length} element${elements.length===1?'':'s'} selected · release to annotate`;
      };
      const scheduleGroupPreview=point=>{
        state.dragPoint=point;if(state.dragFrame)return;
        state.dragFrame=requestAnimationFrame(()=>{state.dragFrame=0;const next=state.dragPoint;state.dragPoint=null;if(next)previewGroup(next)});
      };
      const submit=()=>{
        if(!state.selected||!state.selectionContext)return;const comment=input.value.trim();if(!comment){input.focus();return}
        const context=state.selectionContext,record={source:context.mirror?'sim-mirror':'browser',comment,context,intent:'change',severity:'normal',status:'open'};
        console.log('__CMDY_FEEDBACK__:\#(token):'+JSON.stringify(record));state.marker+=1;
        const pin=document.createElement('div');pin.className='pin';pin.textContent=String(state.marker);const r=state.anchorRect;
        pin.style.left=r.right+'px';pin.style.top=r.top+'px';shadow.appendChild(pin);stop();
      };
      document.addEventListener('pointermove',event=>{if(!state.active||state.selected||isOverlay(event))return;
        if(state.pointer){event.preventDefault();event.stopImmediatePropagation();const point={x:event.clientX,y:event.clientY};
          if(Math.hypot(point.x-state.pointer.x,point.y-state.pointer.y)>5)state.dragging=true;
          if(state.dragging)scheduleGroupPreview(point);return}
        const el=document.elementFromPoint(event.clientX,event.clientY);if(!el||el===host||el===document.documentElement||el===document.body)return;
        if(state.hovered!==el){state.hovered=el;draw(el)}},true);
      document.addEventListener('pointerdown',event=>{if(!state.active||state.selected||isOverlay(event))return;
        const el=document.elementFromPoint(event.clientX,event.clientY);if(!el||el===host)return;
        event.preventDefault();event.stopImmediatePropagation();state.pointer={x:event.clientX,y:event.clientY,element:el};state.dragging=false},true);
      document.addEventListener('pointerup',event=>{if(!state.active||state.selected||!state.pointer||isOverlay(event))return;
        event.preventDefault();event.stopImmediatePropagation();const startPoint=state.pointer,point={x:event.clientX,y:event.clientY};
        cancelDragFrame();state.pointer=null;if(state.dragging){state.dragging=false;const r=rectFromPoints(startPoint,point),elements=elementsInRegion(r);
          if(elements.length)chooseGroup(elements,r);else choose(startPoint.element)}else{choose(startPoint.element)}},true);
      document.addEventListener('pointercancel',()=>{cancelDragFrame();state.pointer=null;state.dragging=false;state.selectedElements=[];if(state.active&&!state.selected){hideHighlight();hint.textContent='click an element or drag a region · esc cancel'}},true);
      document.addEventListener('click',event=>{if(state.active&&!isOverlay(event)){event.preventDefault();event.stopImmediatePropagation()}},true);
      document.addEventListener('keydown',event=>{if(state.active&&event.key==='Escape'){event.preventDefault();event.stopImmediatePropagation();stop()}},true);
      input.addEventListener('keydown',event=>{if(event.key==='Enter'&&!event.shiftKey){event.preventDefault();event.stopPropagation();submit()}});send.addEventListener('click',submit);
      window.__cmdyFeedback={version:3,get active(){return state.active},toggle(){state.active?stop():start()},start,stop,teardown(){stop();host.remove();delete window.__cmdyFeedback}};
      start();return {success:true,active:true};
    })()
    """#
        precondition(source.contains("__CMDY_FEEDBACK__:\(token):"))
        return source
    }
}
