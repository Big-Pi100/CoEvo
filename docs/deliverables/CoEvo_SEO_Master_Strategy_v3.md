> ⛔ **本文已作废**，且**内容已损坏** —— 它经历过一次**错误的编码转换**（整篇 mojibake），
> **原文已不可恢复**。保留仅为记录「曾有此文档」，**不要照本文操作**。

# CoEvo路鍒绘剰杩涘寲瀛︿範 鈥?鍙屽紩鎿嶴EO鏁翠綋浼樺寲绛栫暐 v3.0

> **鏂囨。鐗堟湰**锛歷3.0  
> **閫傜敤鎼滅储骞冲彴**锛氱櫨搴︼紙涓浗锛? Google锛堝叏鐞冿級  
> **鍒涘缓鏃ユ湡**锛?026-07-11  
> **鏈€鍚庢洿鏂?*锛?026-07-11  
> **璐熻矗**锛歋EO 涓撳

---

## 鐩綍

1. [鐜扮姸鐩樼偣涓庤瘖鏂璢(#1-鐜扮姸鐩樼偣涓庤瘖鏂?
2. [鍙屽紩鎿庣瓥鐣ユ€昏](#2-鍙屽紩鎿庣瓥鐣ユ€昏)
3. [鎵ц浼樺厛绾э紙鎸?ROI 鎺掑簭锛塢(#3-鎵ц浼樺厛绾ф寜-roi-鎺掑簭)
4. [Phase 0 路 蹇€熶慨澶嶏紙宸插畬鎴愨渽锛塢(#4-phase-0--蹇€熶慨澶嶅凡瀹屾垚)
5. [Phase 1 路 鎶€鏈疭EO鍔犲浐](#5-phase-1--鎶€鏈痵eo鍔犲浐)
6. [Phase 2 路 鍐呭鐭╅樀寤鸿锛堟帹鑽愪紭鍏堟姇鍏ワ級](#6-phase-2--鍐呭鐭╅樀寤鸿鎺ㄨ崘浼樺厛鎶曞叆)
7. [Phase 3 路 鍏抽敭璇嶄笌鎼滅储鎰忓浘绛栫暐](#7-phase-3--鍏抽敭璇嶄笌鎼滅储鎰忓浘绛栫暐)
8. [Phase 4 路 鏉冨▉涓庨摼鎺ュ缓璁綸(#8-phase-4--鏉冨▉涓庨摼鎺ュ缓璁?
9. [Phase 5 路 Flutter SPA SEO 娣卞害浼樺寲](#9-phase-5--flutter-spa-seo-娣卞害浼樺寲)
10. [Phase 6 路 鐩戞祴浣撶郴鎼缓](#10-phase-6--鐩戞祴浣撶郴鎼缓)
11. [闄勫綍锛氭墽琛屾鏌ユ竻鍗昡(#11-闄勫綍鎵ц妫€鏌ユ竻鍗?

---

## 1. 鐜扮姸鐩樼偣涓庤瘖鏂?
### 1.1 绔欑偣鍩虹淇℃伅

| 椤圭洰 | 鐘舵€?|
|:----|:-----|
| 涓诲煙鍚?| `www.keyievolution.fun`锛堢櫨搴﹁祫婧愬钩鍙版敞鍐屽煙鍚嶏級 |
| 杈呭姪鍩熷悕 | `keyievolution.fun`锛?01 鏈烦杞紝鍙嫭绔嬭闂級 |
| ICP澶囨 | 鉁?绮CP澶?026061557鍙?1 |
| SSL璇佷功 | 鉁?Let's Encrypt锛?026-09-13鍒版湡锛岃嚜鍔ㄧ画鏈?|
| 鏈嶅姟鍣?| 鑵捐浜?2C1G / Ubuntu 22.04 |
| 鎶€鏈爤 | Flutter Web SPA + Rust (axum) 鍚庣 |
| 鍩熷悕鍚庣紑 | 鈿狅笍 `.fun` 闈炵櫨搴﹀亸濂藉悗缂€锛孏oogle 鏃犳樉钁楀亸濂?|

### 1.2 宸插畬鎴愶紙姝ｉ潰锛?
| 椤圭洰 | 璇︽儏 |
|:----|:------|
| 鉁?Baidu绔欓暱楠岃瘉 | `baidu_verify_codeva-k3gx3YOTTR.html` 宸查儴缃?|
| 鉁?robots.txt | 宸查儴缃诧紝sitemap 鎸囧悜 `https://www.keyievolution.fun/sitemap.xml` |
| 鉁?sitemap.xml | 宸查儴缃诧紙2鏉RL锛夛紝缁熶竴浣跨敤 `www` 鍩熷悕 |
| 鉁?SSL鍙屽煙鍚?| `keyievolution.fun` + `www.keyievolution.fun` 鍧囧凡瑕嗙洊 |
| 鉁?鐧惧害缁熻 | `hm.baidu.com` 宸插祵鍏?|
| 鉁?鐧惧害鑷姩鎺ㄩ€?| `zz.bdstatic.com/linksubmit/push.js` 宸插祵鍏?|
| 鉁?缁撴瀯鍖栨暟鎹?| WebApplication銆丗AQPage锛?闂級銆丅readcrumbList銆乄ebSite+SearchAction |
| 鉁?Title / Meta Description | 宸蹭紭鍖栵紝鍚牳蹇冨叧閿瘝 |
| 鉁?Canonical URL | `https://www.keyievolution.fun/app/` |
| 鉁?Open Graph | og:title/description/url/type/site_name/locale/image 瀹屾暣 |
| 鉁?Favicon / PWA Manifest | 宸查厤缃?|
| 鉁?绉诲姩绔?Web App | `mobile-web-app-capable` `apple-mobile-web-app` 宸茶 |
| 鉁?瀛椾綋鏈湴鎵撳寘 | AlibabaPuHuiTi 宓屽叆 Flutter Web bundle锛屾棤澶栭儴鍔犺浇 |
| 鉁?nginx server_name | 鍖呭惈 `www.keyievolution.fun` |
| 鉁?鐖櫕棰勬覆鏌?| `/bot-page` 杩斿洖鍖呭惈瀹屾暣 SEO 鍏冩暟鎹殑闈欐€?HTML |
| 鉁?閮ㄧ讲鏂囨。鍚屾 | `docs/deploy/web-deploy-guide.md` 鍚?SEO 鏂囦欢缁存姢娴佺▼ |

### 1.3 鏈畬鎴?闇€浼樺寲锛堟寜浼樺厛绾э級

| 浼樺厛绾?| 椤圭洰 | 褰撳墠鐘舵€?| 褰卞搷 |
|:------:|:-----|:---------|:-----|
| **P0** | Google Search Console 楠岃瘉 | 馃敀 鍙楅檺锛堝ぇ闄嗘棤娉曡闂級 | 闇€澧冨鎿嶄綔 |
| **P0** | Google Analytics 4 | 馃敀 鍙楅檺锛堝ぇ闄嗘棤娉曡闂級 | 闇€澧冨鎿嶄綔 |
| **P0** | Organization Schema | 鉂?鏈坊鍔?| E-E-A-T 鏉冨▉淇″彿缂哄け |
| **P0** | **鍐呭鐭╅樀锛圔log锛?* | 鉂?鏃犲崥瀹?鍐呭椤甸潰 | 褰撳墠鏈€澶?SEO 缂哄彛锛岄浂鍐呭 = 闆堕暱灏捐瘝娴侀噺 |
| **P1** | nginx gzip 鍘嬬缉 + 闈欐€佹枃浠剁紦瀛?| 鉂?鏈‘璁?閰嶇疆 | 浼犺緭浣撶Н澶э紝褰卞搷鍔犺浇閫熷害 |
| **P2** | Flutter SPA 鍙储寮曟€?| 鈿狅笍 crawler.html 鍏滃簳 | 闀挎湡闇€瑕?SSR锛屼絾褰撳墠 Blog 浼樺厛绾ф洿楂?|
| **P2** | 鐧惧害鐧剧/鐭ラ亾/鏂囧簱/璐村惂 | 鉂?鏈竷灞€ | 鐧惧害鐢熸€佹祦閲?|
| **P3** | 鑵捐浜?CDN | 鉂?鏈帴鍏?| 閿︿笂娣昏姳锛?GB VPS 鍙楃泭鏈夐檺 |
| **P3** | 澶栭摼寤鸿 | 鉂?鏈惎鍔?| 鏈夊唴瀹逛箣鍚庡啀鑰冭檻 |
| **P3** | Flutter SSR / Prerender.io | 鉂?鏈瘎浼?| 绗?3 涓湀璇勪及 |
| **P3** | PageSpeed 娣卞害浼樺寲 | 鉂?鏈祴閲?| 鏈夋祦閲忎箣鍚庡啀浼樺寲 |

---

## 2. 鍙屽紩鎿庣瓥鐣ユ€昏

### 2.1 鎴樼暐閫夋嫨

CoEvo 鏄潰鍚?*涓浗甯傚満 K12 瀛︾敓鍜屽闀?*鐨勪骇鍝併€備絾涓嶅簲鏀惧純 Google锛?
| 缁村害 | 鐧惧害绛栫暐 | Google 绛栫暐 |
|:----|:---------|:------------|
| **鐩爣鐢ㄦ埛** | 涓浗澶ч檰瀹堕暱/K12瀛︾敓 | 娴峰鍗庝汉銆佹腐婢冲彴銆佺暀瀛﹀搴?|
| **鎼滅储浠介** | 涓浗鎼滅储甯傚満 ~60%+ | 鍏ㄧ悆鎼滅储甯傚満 ~90%+ |
| **涓诲煙鍚?* | `www.keyievolution.fun` | `www.keyievolution.fun`锛堢粺涓€锛?|
| **鐢熸€佸竷灞€** | 鐧惧害鐧剧/鐭ラ亾/鏂囧簱/璐村惂 | Google Business Profile / YouTube / Medium |
| **SEO 鎶€鏈爤** | 鐧惧害璧勬簮骞冲彴 / 鐧惧害缁熻 | Search Console / GA4 / PageSpeed Insights |

### 2.2 鍩熷悕绛栫暐

鐢变簬鐧惧害璧勬簮骞冲彴宸叉敞鍐?`www.keyievolution.fun`锛?- **涓诲煙鍚?*锛歚www.keyievolution.fun`锛堢櫨搴︽敞鍐?+ sitemap + canonical 鍧囦娇鐢ㄦ鍩熷悕锛?- **杈呭姪鍩熷悕**锛歚keyievolution.fun` 淇濈暀锛屼笉璺宠浆
- `nginx server_name` 鍚屾椂鍖呭惈涓や釜鍩熷悕

---

## 3. 鎵ц浼樺厛绾э紙鎸?ROI 鎺掑簭锛?
> 鍩轰簬 ROI 璇勪及锛堜环鍊?鎶曞叆姣旓級鎺掑簭锛岃秺闈犲墠鐨勮秺鍏堝仛銆?
| 浼樺厛绾?| 浠诲姟 | 鎶曞叆 | 棰勬湡鏁堟灉 | ROI |
|:------:|:-----|:----|:---------|:---:|
| **P0** | Google Search Console 娉ㄥ唽 + DNS楠岃瘉 | 15鍒嗛挓 | Google 鏀跺綍鍏ュ彛 | 馃敟馃敟馃敟 |
| **P0** | GA4 瀹夎 | 15鍒嗛挓 | 娴侀噺鍩虹嚎 + 杞寲杩借釜 | 馃敟馃敟馃敟 |
| **P0** | **Blog 鍗氬涓婄嚎 + 绗竴绡?Pillar 鏂囩珷** | 3-5澶?| 绗竴涓唴瀹瑰叆鍙ｏ紝闀垮熬璇嶆嬁鎺掑悕 | 馃敟馃敟馃敟馃敟馃敟 |
| **P0** | Organization Schema 娣诲姞 | 5鍒嗛挓 | Google鐭ヨ瘑鍥捐氨 + E-E-A-T淇″彿 | 馃敟馃敟馃敟 |
| **P1** | nginx gzip 纭 + 闈欐€佹枃浠剁紦瀛?| 30鍒嗛挓 | 椤甸潰鍔犺浇閫熷害鎻愬崌 | 馃敟馃敟 |
| **P2** | 鐧惧害鐭ラ亾/鐭ヤ箮甯冨眬 | 姣忓懆1灏忔椂 | 浣庢垚鏈暱灏炬祦閲?| 馃敟馃敟 |
| **P2** | 鎸佺画鍐呭杈撳嚭锛堟瘡鍛?-2绡囧崥瀹級 | 鎸佺画 | 涓婚鏉冨▉寤虹珛锛屾帓鍚嶇Н绱?| 馃敟馃敟馃敟馃敟 |
| **P3** | 鐧惧害鐧剧鍒涘缓 | ~1000鍏?| 鍝佺墝璇嶆悳绱㈢粨鏋滃崰浣?| 馃敟 |
| **P3** | 鑵捐浜?CDN | 1澶?| 鍏ㄥ浗寤惰繜闄嶄綆 | 馃敟 |
| **P3** | Flutter SSR / Prerender.io | 鏁板ぉ | SPA鍐呭鍙储寮?| 馃敟 |
| **P3** | 澶栭摼寤鸿 / 鏁板瓧 PR | 鎸佺画楂樻姇鍏?| Domain Authority鎻愬崌 | 馃敟 |
| 鉂?| 鍛ㄥ害 SEO 鎶ュ憡 | 璺宠繃 | 褰撳墠娴侀噺涓?锛屾病浠€涔堝彲鎶ュ憡鐨?| 鈥?|
| 鉂?| 鎺掑悕杩借釜绯荤粺 | 璺宠繃 | 褰撳墠鎺掑悕涓?锛屾病浠€涔堝ソ杩借釜鐨?| 鈥?|

**鏍稿績鍘熷垯**锛氬唴瀹?SEO锛圔log锛夎繙姣?SPA 鍙储寮曟€ч噸瑕併€傚闀挎悳绱?瀛╁瓙涓嶈嚜瑙夊涔犳€庝箞鍔?鎵惧埌鍗氬鏂囩珷锛屾瘮鎼滅储"CoEvo"鎵惧埌棣栭〉浠峰€煎ぇ 10 鍊嶃€傚湪 Blog 涓婄嚎骞朵骇鐢熸祦閲忎箣鍓嶏紝鍏朵粬鎵€鏈変簨閮芥槸閿︿笂娣昏姳銆?
---

## 4. Phase 0 路 蹇€熶慨澶嶏紙宸插畬鎴愨渽锛?
> 浠ヤ笅浠诲姟宸插湪 2026-07-11 瀹屾垚銆?
### 鉁?4.1 鐧惧害璧勬簮骞冲彴娉ㄥ唽楠岃瘉

- 绔欑偣 `www.keyievolution.fun` 宸查獙璇?- 楠岃瘉鏂囦欢 `baidu_verify_codeva-k3gx3YOTTR.html` 閮ㄧ讲鍦?`/opt/coevo/admin-web/` 鍜?`/var/www/coevo-landing/`
- 宸叉彁浜?`/bot-page` 鍒?URL 鏀跺綍

### 鉁?4.2 robots.txt + sitemap 淇

- robots.txt sitemap URL 浠?`keyievolution.fun` 淇涓?`www.keyievolution.fun`
- sitemap.xml 鍖呭惈 2 鏉?URL锛坄/` 鍜?`/app/`锛夛紝鍏ㄩ儴浣跨敤 `www` 鍩熷悕
- 宸插悓姝ュ埌 `/opt/coevo/admin-web/` 鍜?`/var/www/coevo-landing/`

### 鉁?4.3 JSON-LD 缁撴瀯鍖栨暟鎹?
| Schema | 鍐呭 | 鐢ㄩ€?|
|:-------|:-----|:-----|
| WebApplication | CoEvo AI鐗圭骇鏁欏笀鎻忚堪 + 鍏嶈垂瀹氫环 | 鎼滅储缁撴灉灞曠ず |
| FAQPage | 8鏉″父瑙侀棶棰橀棶绛?| 鎼滅储缁撴灉鎶樺彔灞曠幇 |
| BreadcrumbList | 棣栭〉鈫扐I瀛︿範骞冲彴 | 闈㈠寘灞戝鑸?|
| WebSite + SearchAction | 绔欑偣鎼滅储 | 鎼滅储妗嗗睍绀?|

### 鉁?4.4 Open Graph / 绀句氦濯掍綋

- og:title / og:description / og:url / og:image锛?12px锛夊畬鏁?
### 鉁?4.5 Canonical URL

- `<link rel="canonical" href="https://www.keyievolution.fun/app/">`

### 鉁?4.6 鐧惧害缁熻 + 鑷姩鎺ㄩ€?
- `hm.baidu.com` 缁熻浠ｇ爜宸插祵鍏?- `zz.bdstatic.com/linksubmit/push.js` 鑷姩鎺ㄩ€佸凡宓屽叆

### 鉁?4.7 鐖櫕棰勬覆鏌撻〉

- `/bot-page` 鎻愪緵瀹屾暣 SEO 鍏冩暟鎹殑闈欐€?HTML
- `crawler.html` 鐢?Flutter 鏋勫缓鐨?`index.html` 澶嶅埗鐢熸垚
- 閮ㄧ讲鏃惰嚜鍔ㄥ悓姝ワ紙瑙?`web-deploy-guide.md` 搂4.2锛?
### 鉁?4.8 閮ㄧ讲鏂囨。鏇存柊

- `docs/deploy/web-deploy-guide.md` 鏂板 搂4.3 SEO 鏂囦欢缁存姢绔犺妭
- 姣忔閮ㄧ讲鍚庨渶鍚屾 robots.txt銆乻itemap.xml銆乥aidu_verify銆乧rawler.html

### 鉁?4.9 nginx 鍩熷悕瀵归綈

- HTTPS server_name 鍖呭惈 `www.keyievolution.fun`

---

## 5. Phase 1 路 鎶€鏈疭EO鍔犲浐

> **褰卞搷/鎶曞叆姣旀瀬楂橈紝绔嬪嵆鎵ц銆?*

### 5.1 P0 路 Google Search Console 娉ㄥ唽

1. 璁块棶 [search.google.com/search-console](https://search.google.com/search-console)
2. 娣诲姞灞炴€э細`https://www.keyievolution.fun`
3. 鎺ㄨ崘楠岃瘉鏂瑰紡锛?*DNS TXT 璁板綍楠岃瘉**锛圖NSPod 鎿嶄綔绠€鍗曪級
4. 鎻愪氦 sitemap锛歚https://www.keyievolution.fun/sitemap.xml`
5. 閰嶇疆棣栭€夊煙鍚嶏細`https://www.keyievolution.fun`

### 5.2 P0 路 GA4 瀹夎

1. 鍒涘缓 GA4 濯掍綋璧勬簮
2. 鑾峰彇娴嬮噺 ID锛坄G-XXXXXXXXXX`锛?3. 鍦?`app/web/index.html` `<head>` 涓坊鍔?GA4 浠ｇ爜锛?
```html
<!-- Google Analytics -->
<script async src="https://www.googletagmanager.com/gtag/js?id=G-XXXXXXXXXX"></script>
<script>
  window.dataLayer = window.dataLayer || [];
  function gtag(){dataLayer.push(arguments);}
  gtag('js', new Date());
  gtag('config', 'G-XXXXXXXXXX');
</script>
```

4. 閰嶇疆鍏抽敭杞寲浜嬩欢锛堝彲閫夛紝Blog 鏈夋祦閲忓悗鍐嶅仛锛夛細
   - `sign_up`锛堢敤鎴锋敞鍐岋級銆乣start_trial`锛堝紑濮嬭瘯鐢級銆乣purchase`锛堜粯璐硅喘涔帮級

### 5.3 P0 路 Organization Schema 娣诲姞

鍦?`app/web/index.html` 鐨?JSON-LD 涓拷鍔狅細

```json
{
  "@context": "https://schema.org",
  "@type": "Organization",
  "name": "鍒绘剰杩涘寲瀛︿範",
  "alternateName": "CoEvo",
  "url": "https://www.keyievolution.fun/",
  "logo": "https://www.keyievolution.fun/icons/Icon-512.png",
  "description": "鍩轰簬FSRS璁板繂绠楁硶鐨凙I鐗圭骇鏁欏笀骞冲彴",
  "foundingDate": "2026",
  "contactPoint": {
    "@type": "ContactPoint",
    "contactType": "customer support",
    "email": "admin@keyievolution.fun"
  }
}
```

### 5.4 P1 路 nginx gzip 纭

```bash
ssh -i ~/.ssh/coevo_key ubuntu@<OLD_VPS_IP> "
  grep -E 'gzip|gzip_' /etc/nginx/nginx.conf
"
```

濡傛湭寮€鍚紝鍦?nginx.conf 鐨?http 鍧椾腑娣诲姞锛?```nginx
gzip on;
gzip_vary on;
gzip_proxied any;
gzip_comp_level 6;
gzip_types text/plain text/css text/xml application/json application/javascript image/svg+xml;
```

**棰勬湡鏁堟灉**锛欽S/CSS/JSON 浼犺緭浣撶Н鍑忓皯 60-70%銆?
### 5.5 P1 路 闈欐€佹枃浠跺己缂撳瓨

鍦?`/etc/nginx/sites-available/coevo` 涓坊鍔狅細

```nginx
location ~* \.(js|css|woff2?|ttf|png|jpg|webp|svg)$ {
    expires 1y;
    add_header Cache-Control "public, immutable";
}
```

**棰勬湡鏁堟灉**锛氶娆″姞杞藉悗锛岄潤鎬佽祫婧愪笉鍐嶉噸澶嶈姹傘€?
### 5.6 鈴革笍 鎼佺疆椤癸紙鏈夋祦閲忓悗鍐嶅仛锛?
| 椤圭洰 | 鍘熷洜 |
|:-----|:------|
| Title/Description 寰皟 | 褰撳墠宸蹭笉閿欙紝浼樺寲绌洪棿鏈夐檺 |
| 鑵捐浜?CDN | 1GB VPS 甯﹀鏈夐檺锛孋DN 鍙楃泭涓嶉珮锛屼笖澧炲姞澶嶆潅搴?|
| 鍥剧墖閲嶅懡鍚?| Flutter 妗嗘灦鎺у埗娓叉煋锛屽奖鍝嶅皬 |

---

## 6. Phase 2 路 鍐呭鐭╅樀寤鸿锛堟帹鑽愪紭鍏堟姇鍏ワ級

> **杩欐槸褰撳墠鏈€澶х殑 SEO 缂哄彛銆?* 闆跺唴瀹归〉闈?= 闆朵富棰樻潈濞?= 闆堕暱灏捐瘝娴侀噺銆? 
> **寤鸿浼樺厛浜?Phase 1 鏈畬鎴愰」鎶曞叆銆?* 涓€绡囧ソ鏂囩珷甯︽潵鐨勬祦閲忎环鍊?> 鎵€鏈夋妧鏈?SEO 浼樺寲鐨勬€诲拰銆?
### 6.1 鎺ㄨ崘鏂规锛欻ugo 闈欐€佸崥瀹?
```
www.keyievolution.fun/blog/
鈹斺攢鈹€ Hugo 闈欐€佺珯鏋勫缓
鈹斺攢鈹€ Nginx 鍙嶅悜浠ｇ悊鍒?/blog/ 璺緞
鈹斺攢鈹€ 鍏变韩涓诲煙鍝佺墝鏉冮噸锛屽唴閾惧洖棣栭〉
```

**鎶€鏈疄鐜?*锛?```nginx
location /blog/ {
    alias /var/www/coevo-blog/public/;
    index index.html;
    try_files $uri $uri/ /blog/index.html;
}
```

**涓轰粈涔堢敤 Hugo 鑰屼笉鏄斁鍦?Flutter 鍐?*锛欶lutter SPA 鐨勭埇铏彲绱㈠紩鎬ф槸纭激銆傜嫭绔嬮潤鎬佺珯褰撳ぉ涓婄嚎銆佸綋澶╄鏀跺綍銆?
### 6.2 鍐呭涓婚鏋舵瀯锛圱opic Cluster锛?
#### 涓婚涓€锛欰I鏁欒偛涓庡涔犳柟娉曪紙鏍稿績涓婚锛?
| 绫诲瀷 | 鍐呭 | 鐩爣鍏抽敭璇?| 瀛楁暟 |
|:----|:-----|:----------|:----:|
| **Pillar** | AI 鍒板簳鑳戒笉鑳藉府瀛╁瓙鎻愬垎锛熲€斺€?026 K12 AI瀛︿範鍏ㄩ潰璇勬祴 | AI鏁欒偛 / AI杈呭鏁堟灉 | 3000+ |
| Cluster 1 | FSRS 璁板繂绠楁硶 vs 鑹惧娴╂柉閬楀繕鏇茬嚎锛氬摢涓洿绉戝锛?| FSRS璁板繂绠楁硶 / 闂撮殧閲嶅 | 2000+ |
| Cluster 2 | K12 瀛︾敓閫傚悎鐢?AI 鑷鍚楋紵缁忛獙鍜岄闄?| K12 AI瀛︿範 / AI鑷 | 2000+ |
| Cluster 3 | AI 涓€瀵逛竴杈呭鍜岀嚎涓嬭緟瀵肩彮锛屽摢涓垝绠楋紵 | AI涓€瀵逛竴浠锋牸 / AI杈呭 vs 杈呭鐝?| 1500+ |
| Cluster 4 | 2026 骞村闀垮繀鐭ョ殑 5 涓?AI 瀛︿範宸ュ叿 | AI瀛︿範宸ュ叿鎺ㄨ崘 / 瀛︿範宸ュ叿璇勬祴 | 2000+ |

#### 涓婚浜岋細璁板繂涓庡涔犵瀛?
| 绫诲瀷 | 鍐呭 | 鐩爣鍏抽敭璇?| 瀛楁暟 |
|:----|:-----|:----------|:----:|
| **Pillar** | 閬楀繕鏇茬嚎銆丗SRS銆佷富鍔ㄥ洖蹇嗭細绉戝鐨勫涔犳柟娉?| 绉戝澶嶄範 / 璁板繂鏇茬嚎 / FSRS | 2500+ |
| Cluster 1 | 涓轰粈涔堝浜嗗氨蹇橈紵鈥斺€旇鐭ョ瀛︾殑绛旀 | 瀛︿簡灏卞繕鎬庝箞鍔?/ 璁板繂鍘熺悊 | 1500+ |
| Cluster 2 | 涓诲姩鍥炲繂娉曪細姣斿弽澶嶇炕涔︽湁鏁?10 鍊嶇殑瀛︿範鎶€宸?| 涓诲姩鍥炲繂瀛︿範娉?/ 楂樻晥澶嶄範鏂规硶 | 2000+ |
| Cluster 3 | 闂撮殧閲嶅锛氭瘡澶?15 鍒嗛挓璁扮墷涓€鍒?| 闂撮殧閲嶅 / 闂撮殧澶嶄範 | 1500+ |

#### 涓婚涓夛細瀹堕暱鏁欒偛鍐崇瓥

| 绫诲瀷 | 鍐呭 | 鐩爣鍏抽敭璇?| 瀛楁暟 |
|:----|:-----|:----------|:----:|
| **Pillar** | 2026 骞?K12 瀹跺涵鏁欒偛鎶曞叆鎸囧崡 | K12鏁欒偛鎶曞叆 / 瀹跺涵鏁欒偛瑙勫垝 | 2500+ |
| Cluster 1 | 瀛╁瓙涓嶈嚜瑙夊涔犳€庝箞鍔烇紵鈥斺€旇涓鸿璁″鐨勬柟娉?| 瀛╁瓙涓嶈嚜瑙?/ 鑷富瀛︿範鍩瑰吇 | 2000+ |
| Cluster 2 | AI 瀛︿範浜у搧鎬庝箞閫夛紵6 涓淮搴﹀府浣犲垽鏂?| AI瀛︿範浜у搧鎺ㄨ崘 / AI鏁欒偛浜у搧閫夋嫨 | 2000+ |

### 6.3 鍐呭璐ㄩ噺瑕佹眰

- 姣忕瘒鍘熷垱锛屽瓧鏁?1500-3000 瀛?- 鍚綔鑰呯讲鍚嶅拰绠€浠嬶紙E-E-A-T 淇″彿锛?- 寮曠敤鏉冨▉鏉ユ簮锛堣鏂囥€佸畼鏂规暟鎹級
- 鍐呴摼鍥炲埌涓婚〉 `/app/` 鍜屾枃绔犵浉浜掗摼鎺?- 棣栧浘浼樺寲锛堣涔夊寲鍛藉悕 + alt 灞炴€э級

### 6.4 鍙戝竷鑺傚

| 鍛ㄦ | 鍐呭 | 绫诲瀷 |
|:----|:-----|:-----|
| 绗?鍛?| Blog 涓婄嚎 + AI鏁欒偛璇勬祴 Pillar (3000瀛? | 鏀煴鍐呭 |
| 绗?鍛?| FSRS vs 鑹惧娴╂柉 (2000瀛? + 绉戝澶嶄範 Pillar (2500瀛? | 闆嗙兢+鏀煴 |
| 绗?鍛?| K12 AI鑷鎸囧崡 (2000瀛? + 涓诲姩鍥炲繂娉?(2000瀛? | 闆嗙兢鍐呭 |
| 绗?鍛?| AI涓€瀵逛竴 vs 杈呭鐝?(1500瀛? + 瀛╁瓙涓嶈嚜瑙夋€庝箞鍔?(2000瀛? | 闆嗙兢鍐呭 |
| 鍚庣画 | 淇濇寔姣忓懆 1-2 绡?| 鎸佺画 |

---

## 7. Phase 3 路 鍏抽敭璇嶄笌鎼滅储鎰忓浘绛栫暐

> **鍚姩鏉′欢**锛欱log 涓婄嚎骞惰嚦灏戞湁 4 绡囨枃绔犲悗銆?
### 7.1 鎺ㄨ崘鍏抽敭璇嶅伐鍏?
| 宸ュ叿 | 鐢ㄩ€?|
|:-----|:------|
| Google Search Console | 鐪熷疄鎼滅储鏌ヨ鏁版嵁锛堝厤璐癸級 |
| Google Keyword Planner | 鎼滅储閲?绔炰簤搴︿及绠?|
| 鐧惧害鎸囨暟 | 鎼滅储瓒嬪娍鍜屼汉缇ょ敾鍍?|
| 5118.com | 鐧惧害闀垮熬璇嶆寲鎺橈紙浠樿垂鍩虹鐗堬級 |

### 7.2 鎼滅储鎰忓浘鏄犲皠

```
Top-of-Funnel (淇℃伅瀛︿範)    鈫?鍗氬鍐呭
  鍏抽敭璇嶏細FSRS銆侀棿闅旈噸澶嶃€佽蹇嗗師鐞嗐€佸浜嗗氨蹇?  鐩爣锛氭祦閲忓叆鍙ｃ€佸缓绔嬩笓涓氳鐭?
Middle-of-Funnel (鍟嗕笟璋冩煡) 鈫?璇勬祴瀵规瘮
  鍏抽敭璇嶏細AI鏁欒偛鍝釜濂姐€丄I瀛︿範宸ュ叿鎺ㄨ崘銆丄I涓€瀵逛竴鎬庝箞鏍?  鐩爣锛氬紩瀵兼瘮杈冦€佸缓绔嬩俊浠?
Bottom-of-Funnel (浜ゆ槗鍐崇瓥) 鈫?棣栭〉 + 浜у搧椤?  鍏抽敭璇嶏細AI涓€瀵逛竴杈呭銆丄I鐗圭骇鏁欏笀銆丆oEvo浠锋牸
  鐩爣锛氳浆鍖栨敞鍐?璇曠敤
```

---

## 8. Phase 4 路 鏉冨▉涓庨摼鎺ュ缓璁?
> **鍚姩鏉′欢**锛欱log 绋冲畾杈撳嚭 2 涓湀浠ヤ笂锛屾湁鍐呭鍩虹鍚庡啀鍋氥€?
### 8.1 浼樺厛鍋氾紙浣庢垚鏈級

| 椤圭洰 | 鎶曞叆 | 棰勬湡 |
|:-----|:----|:------|
| 鐧惧害鐭ラ亾鎶曟斁 | 姣忓懆 30鍒嗛挓 | 闀垮熬璇嶅崰浣?|
| 鐭ヤ箮闂瓟 | 姣忓懆 30鍒嗛挓 | 鍝佺墝鏇濆厜 + 澶栭摼 |

### 8.2 鏈夐绠楁椂鍋?
| 椤圭洰 | 棰勭畻 | 棰勬湡 |
|:-----|:-----|:------|
| 鐧惧害鐧剧鍝佺墝璇嶆潯 | ~500-2000鍏?| 鍝佺墝鎼滅储 Top3 鍗犱綅 |
| 鐧惧害鏂囧簱鐧界毊涔?| 1澶╂挵鍐?| 鐧惧害鐢熸€佸唴瀹规矇娣€ |

### 8.3 鏆傜紦锛堟湁娴侀噺鍚庡啀鑰冭檻锛?
- 澶栭摼 Outreach / Guest Post
- 鏁板瓧 PR锛堝獟浣撹仈绯伙級
- GitHub 寮€婧?- G2/Capterra 浜у搧鍒楄〃

---

## 9. Phase 5 路 Flutter SPA SEO 娣卞害浼樺寲

> **璇勪及鏃堕棿**锛氱 3 涓湀銆?
### 9.1 褰撳墠鏂规

- `/bot-page` 鎻愪緵闈欐€?HTML 缁欑櫨搴︼紙鉁?宸插疄鏂斤級
- `crawler.html` 鐢?`index.html` 澶嶅埗鐢熸垚

### 9.2 璇勪及璺嚎

| 鏃堕棿 | 鏂规 | 鍘熷洜 |
|:-----|:-----|:------|
| 鐜板湪 | 淇濇寔 crawler.html | 蹇€熶笂绾匡紝鑷冲皯璁╃埇铏鍒扮粨鏋勫寲鏁版嵁 |
| 绗?-4鍛?| Blog 浼樺厛 | 鍐呭 SEO 杩滄瘮 SPA 鍙储寮曟€ч噸瑕?|
| 绗?涓湀 | 璇勪及 Flutter SSR / Prerender.io | 鏈夋祦閲忓悗鏈夎瘎浼颁环鍊?|

---

## 10. Phase 6 路 鐩戞祴浣撶郴鎼缓

### 10.1 褰撳墠鐩戞祴

| 宸ュ叿 | 鐘舵€?| 鐢ㄩ€?|
|:-----|:----|:------|
| 鐧惧害璧勬簮骞冲彴 | 鉁?宸查厤 | 鐧惧害鏀跺綍鐩戞祴 |
| 鐧惧害缁熻 | 鉁?宸查厤 | 鐧惧害娴侀噺鍒嗘瀽 |

### 10.2 闇€琛ュ厖

| 宸ュ叿 | 鐘舵€?| 鐢ㄩ€?|
|:-----|:----|:------|
| Google Search Console | 鉂?寰呴厤锛圥0锛?| Google 鏀跺綍鐩戞祴 |
| GA4 | 鉂?寰呴厤锛圥0锛?| Google 娴侀噺鍒嗘瀽 |

### 10.3 鏆傜紦

| 宸ュ叿 | 鍘熷洜 |
|:-----|:------|
| 鍛ㄥ害 SEO 鎶ュ憡 | 褰撳墠娴侀噺涓?0锛屾病浠€涔堝彲鎶ュ憡鐨勩€傛湀搴﹀嵆鍙?|
| 鎺掑悕杩借釜绯荤粺 | 褰撳墠鎺掑悕涓?0锛屾病浠€涔堝ソ杩借釜鐨勩€侭log 涓婄嚎鍚庡啀寤虹珛 |

### 10.4 鏍稿績 KPI 鐩爣

| 鎸囨爣 | 褰撳墠 | 绗?涓湀 | 绗?涓湀 | 绗?涓湀 |
|:-----|:----|:-------|:-------|:-------|
| 鐧惧害鏀跺綍 URL | 0 | 3+ | 20+ | 50+ |
| Google 鏀跺綍 URL | 0 | 5+ | 30+ | 100+ |
| 鍐呭鍙戝竷鏁?| 0 | 4 | 16 | 40+ |
| 鐧惧害鏈堟湁鏈虹偣鍑?| 0 | 50+ | 300+ | 1000+ |
| Google 鏈堟湁鏈虹偣鍑?| 0 | 100+ | 500+ | 2000+ |
| 鍝佺墝璇嶆帓鍚嶏紙鍙屽钩鍙帮級 | 鏃?| 鍓? | 鍓? | #1 |

---

## 11. 闄勫綍锛氭墽琛屾鏌ユ竻鍗?
### Phase 0 路 蹇€熶慨澶嶏紙宸插畬鎴愶級

- [x] 鐧惧害璧勬簮骞冲彴娉ㄥ唽 + 楠岃瘉
- [x] robots.txt 鍩熷悕淇 + sitemap URL 缁熶竴
- [x] sitemap.xml 浣跨敤 `www.keyievolution.fun`
- [x] nginx server_name 鍖呭惈 www
- [x] JSON-LD: WebApplication + FAQPage + BreadcrumbList + WebSite
- [x] Canonical URL: `https://www.keyievolution.fun/app/`
- [x] Open Graph: title/description/url/image 瀹屾暣
- [x] 鐧惧害缁熻 + 鑷姩鎺ㄩ€?- [x] crawler.html 棰勬覆鏌撻〉锛坄/bot-page`锛?- [x] 閮ㄧ讲鏂囨。鍚屾锛坄web-deploy-guide.md` 搂4.3锛?
### Phase 1 路 鎶€鏈疭EO锛堢珛鍗虫墽琛岋級

- [ ] Google Search Console 娉ㄥ唽 + DNS 楠岃瘉 -> [ ] 鎻愪氦 sitemap
- [ ] GA4 瀹夎骞堕獙璇佹暟鎹敹闆?- [ ] Organization Schema 娣诲姞鍒?`app/web/index.html`
- [ ] nginx gzip 纭寮€鍚?- [ ] 闈欐€佹枃浠跺己缂撳瓨閰嶇疆

### Phase 2 路 鍐呭鐭╅樀锛堜紭鍏堟姇鍏ワ級

- [ ] Hugo 鍗氬绔欑偣鎼缓
- [ ] Nginx /blog/ 璺敱閰嶇疆
- [ ] 绗竴绡?Pillar 鏂囩珷锛圓I鏁欒偛璇勬祴, 3000瀛楋級
- [ ] 鍗氬 sitemap 鎻愪氦鍙屽钩鍙?- [ ] FSRS vs 鑹惧娴╂柉 (2000瀛?
- [ ] 绉戝澶嶄範 Pillar (2500瀛?
- [ ] K12 AI鑷鎸囧崡 (2000瀛?
- [ ] 涓诲姩鍥炲繂娉?(2000瀛?
- [ ] 鐧惧害鐭ラ亾/鐭ヤ箮鍚屾甯冨眬

### Phase 3-6锛堝悗缁寜搴忔墽琛岋級

- [ ] Google Search Console 鎬ц兘鏁版嵁妫€鏌ワ紙Blog 涓婄嚎鍚庯級
- [ ] 鍏抽敭璇嶆帓鍚嶈拷韪缓绔嬶紙4绡囨枃绔犲悗锛?- [ ] 鐧惧害鐧剧鍒涘缓锛堟湁棰勭畻鏃讹級
- [ ] Flutter SSR / Prerender.io 璇勪及锛堢3涓湀锛?- [ ] 鏈堝害 SEO 鎶ュ憡锛堟湁娴侀噺鍚庯級

