/*
 * Stream-All 流媒体解锁检测 - 并发增强版
 * 基于 Rabbit-Spec / Surge 的 Stream-All 面板检测逻辑改进
 * 原始项目：https://github.com/Rabbit-Spec/Surge
 * 修改日期：2026-11-11（修复 Netflix 仅自制剧误报）
 * Netflix 非自制：Ninjago (81280792)、Breaking Bad (70143836)、Suits (70195800)、Brooklyn 99 (70281562)
 * Netflix 自制测试：Test Patterns (80018499)
 * YouTube / Netflix / Disney+ 与五个 Netflix 探针均并发检测
 */

const REQUEST_HEADERS = {
  'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/94.0.4606.61 Safari/537.36',
  'Accept-Language': 'en',
}
const TIMEOUT_MS = 7000

// 单个请求失败不会阻塞其他并发任务。请求超时也会正常返回。
function request(url) {
  return new Promise((resolve) => {
    let settled = false
    let timer
    const finish = (value) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      resolve(value)
    }
    timer = setTimeout(() => finish({ error: 'timeout' }), TIMEOUT_MS)
    try {
      $httpClient.get({ url, headers: REQUEST_HEADERS }, (error, response, data) => {
        if (error || !response) {
          finish({ error: 'request' })
          return
        }
        finish({
          status: Number(response.status || response.statusCode || 0),
          headers: response.headers || {},
          body: typeof data === 'string' ? data : '',
        })
      })
    } catch (error) {
      finish({ error: 'request' })
    }
  })
}

function getRegion(headers) {
  const key = Object.keys(headers).find((name) => name.toLowerCase() === 'x-originating-url')
  if (!key) return ''
  const url = String(headers[key] || '')
  const match = url.match(/netflix[.]com[/](?:([a-z]{2})(?:-[a-z]{2})?[/])?title[/]/i)
  if (!match) return ''
  // 仅在 Netflix 自己提供的 URL 没有地区路径时沿用原版 US 推断。
  return (match[1] || 'US').toUpperCase()
}

// Netflix 当前会在“不可观看”的详情页上返回 HTTP 200。
// 因此检测仅依据网页可访问性及明确的地区限制提示；不能证明真正可以播放。
function netflixPageBlocked(body) {
  if (!body) return false
  const html = String(body).replace(/\\u2019|\\u0027|&#8217;|&#x2019;|&rsquo;/gi, "'")
  return /this title.{0,120}(?:isn.t|is not|not).{0,90}available to watch in your country|this title.{0,90}not available in your current region|(?:oh no.{0,80})?this title.{0,80}unavailable to watch|(?:目前|当前).{0,24}(?:无法|無法|不可).{0,24}(?:播放|觀看|观看)|(?:无法|無法).{0,24}(?:在您所在|在你所在).{0,24}(?:观看|觀看)/i.test(html)
}

async function checkNetflix() {
  // 四个非自制剧交叉检测 + Test Patterns；所有请求同时启动。
  // 单个片名可能因地区版权不可用，不可将其视为“仅自制剧”证据。
  const titles = [
    { id: 81280792, name: 'Ninjago' },
    { id: 70143836, name: 'BreakingBad' },
    { id: 70195800, name: 'Suits' },
    { id: 70281562, name: 'Brooklyn99' },
    { id: 80018499, name: 'TestPatterns' },
  ]
  const responses = await Promise.all(titles.map((item) =>
    request('https://www.netflix.com/title/' + item.id)))
  const probes = responses.map((res, i) => {
    const http = res.status || 0
    const region = getRegion(res.headers || {})
    const state = http === 200
      ? (netflixPageBlocked(res.body) ? 'geo-blocked' : 'page-200')
      : (http === 403 || http === 404 ? 'http-denied' : 'error')
    return { name: titles[i].name, id: titles[i].id, region, http, state }
  })
  console.log('Netflix probes (not playback): ' +
    probes.map((p) => p.name + '=' + p.state + '/' + p.http +
      (p.region ? '/' + p.region : '')).join(', '))

  const nonOriginal = probes.slice(0, 4)
  const original = probes[4]
  const pages = nonOriginal.filter((p) => p.state === 'page-200').length
  const region = (probes.find((p) => p.region) || {}).region || ''
  const label = region ? ' ➟ ' + region : ''

  // 未登录的页面探测不等于已登录账号真正可以播放，不再断言“完整解锁”。
  if (pages > 0) {
    return 'Netflix: 非自制网页可访问 ' + pages + '/4' + label + '（未验播放）'
  }

  // 页面返回 403/404 或特定片名被限制，不能推出整个非自制片库都不可用。
  // 仅自制剧分类需要实际播放或明确的代理限制证据才能确认。
  if (original.state === 'page-200') {
    return 'Netflix: 自制剧网页通过，非自制待确认' + label
  }
  if (probes.every((p) => p.state === 'geo-blocked' || p.state === 'http-denied')) {
    return 'Netflix: 页面检测未通过' + label + '（需实测）'
  }
  return 'Netflix: 检测不确定，请查看日志' + label
}

async function checkYouTube() {
  const res = await request('https://www.youtube.com/premium')
  if (res.error || res.status !== 200) return 'YouTube: 检测失败，请刷新面板'
  if (res.body.includes('Premium is not available in your country')) return 'YouTube: 不支持解锁'
  const code = res.body.match(/"countryCode":"(.*?)"/)
  const region = code ? code[1].toUpperCase() : res.body.includes('www.google.cn') ? 'CN' : 'US'
  return 'YouTube: 已解锁 ➟ ' + region
}

// Disney+ 官网和设备地区 API 同时检测；不再依赖旧网页的 CNBL 注释。
function disneyLocation() {
  return new Promise((resolve) => {
    let finished = false
    const timer = setTimeout(() => finish({ error: 'timeout' }), TIMEOUT_MS)
    function finish(result) {
      if (finished) return
      finished = true
      clearTimeout(timer)
      resolve(result)
    }

    const option = {
      url: 'https://disney.api.edge.bamgrid.com/graph/v1/device/graphql',
      headers: {
        'Accept-Language': 'en',
        'Content-Type': 'application/json',
        'User-Agent': REQUEST_HEADERS['User-Agent'],
        Authorization: 'ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84',
      },
      body: JSON.stringify({
        query: 'mutation registerDevice($input: RegisterDeviceInput!) { registerDevice(registerDevice: $input) { grant { grantType assertion } } }',
        variables: {
          input: {
            applicationRuntime: 'chrome',
            attributes: {
              browserName: 'chrome',
              browserVersion: '94.0.4606',
              manufacturer: 'apple',
              model: null,
              operatingSystem: 'macintosh',
              operatingSystemVersion: '10.15.7',
              osDeviceIds: [],
            },
            deviceFamily: 'browser',
            deviceLanguage: 'en',
            deviceProfile: 'macosx',
          },
        },
      }),
    }

    try {
      $httpClient.post(option, (error, response, data) => {
        if (error || !response) {
          finish({ error: 'request' })
          return
        }
        const status = Number(response.status || response.statusCode || 0)
        if (status !== 200) {
          finish({ error: 'HTTP ' + status })
          return
        }
        try {
          const parsed = typeof data === 'string' ? JSON.parse(data) : data
          if (parsed.errors) {
            finish({ error: 'graphql' })
            return
          }
          const session = parsed.extensions && parsed.extensions.sdk &&
            parsed.extensions.sdk.session
          if (!session || !session.location || !session.location.countryCode ||
              (session.inSupportedLocation !== true && session.inSupportedLocation !== false &&
               session.inSupportedLocation !== 'true' && session.inSupportedLocation !== 'false')) {
            finish({ error: 'no location' })
            return
          }
          finish({
            region: String(session.location.countryCode).toUpperCase(),
            supported: session.inSupportedLocation === true || session.inSupportedLocation === 'true',
          })
        } catch (error) {
          finish({ error: 'parse' })
        }
      })
    } catch (error) {
      finish({ error: 'request' })
    }
  })
}

async function checkDisney() {
  const [home, geo] = await Promise.all([
    request('https://www.disneyplus.com/'),
    disneyLocation(),
  ])

  console.log('Disney+: homeHTTP=' + (home.status || home.error) +
    ', geo=' + (geo.error || (geo.region + '/' + geo.supported)))

  if (geo.region) {
    if (geo.supported) return 'Disney+: 已解锁 ➟ ' + geo.region
    // 不支持地区但网页能访问：区分未上线与真正被拒绝的区域。
    if (home.status === 200 &&
        !/Sorry, Disney\+ is not available in your region[.]|error.code.73|forbidden.location/i.test(home.body)) {
      return 'Disney+: 即将登陆 ➟ ' + geo.region
    }
    return 'Disney+: 未支持 🚫 ➟ ' + geo.region
  }

  if (home.status === 403 || home.status === 404 ||
      /Sorry, Disney\+ is not available in your region[.]|error.code.73|forbidden.location/i.test(home.body || '')) {
    return 'Disney+: 未支持 🚫'
  }
  if (geo.error === 'timeout') return 'Disney+: 检测超时 🚦'
  return 'Disney+: 检测异常 ❌'
}

;(async () => {
  const panel = {
    title: '流媒体解锁检测',
    content: '',
    icon: 'play.tv.fill',
    'icon-color': '#FF2D55',
  }
  try {
    // 所有平台在同一轮事件循环内启动，面板仍按原来的顺序展示。
    const result = await Promise.all([checkYouTube(), checkNetflix(), checkDisney()])
    panel.content = result.join('\n')
  } catch (error) {
    console.log('Stream-All error: ' + error)
    panel.content = '检测失败，请刷新面板'
  } finally {
    $done(panel)
  }
})()
