/*
 * Stream-All 流媒体解锁检测 - 并发增强版
 * 基于 Rabbit-Spec / Surge 的 Stream-All 面板检测逻辑改进
 * 原始项目：https://github.com/Rabbit-Spec/Surge
 * 修改日期：2026-11-11
 * Netflix 非自制内容：LEGO Ninjago (81280792)、Breaking Bad (70143836)
 * Netflix 自制测试：Test Patterns (80018499)
 * YouTube / Netflix / Disney+ 与三个 Netflix 探针均并发检测
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

async function checkNetflix() {
  const ids = [81280792, 70143836, 80018499]
  const results = await Promise.all(ids.map((id) => request('https://www.netflix.com/title/' + id)))
  const probes = results.map((res) => {
    if (res.status === 200) return { state: 'available', region: getRegion(res.headers) }
    if (res.status === 403 || res.status === 404) return { state: 'unavailable' }
    return { state: 'error' }
  })
  const nonOriginal = probes.slice(0, 2)
  const original = probes[2]
  const full = nonOriginal.find((item) => item.state === 'available')
  const region = (full && full.region) || original.region || ''
  const regionLabel = region ? ' ➟ ' + region : '（地区未知）'

  console.log('Netflix probes: Ninjago=' + probes[0].state +
    ', BreakingBad=' + probes[1].state + ', TestPatterns=' + probes[2].state)

  if (full) return 'Netflix: 已完整解锁' + regionLabel
  if (original.state === 'available') {
    if (nonOriginal.every((item) => item.state === 'unavailable')) {
      return 'Netflix: 仅解锁自制剧' + regionLabel
    }
    return 'Netflix: 自制剧可用，非自制剧检测异常' + regionLabel
  }
  if (original.state === 'unavailable' && nonOriginal.every((item) => item.state === 'unavailable')) {
    return 'Netflix: 该节点不支持解锁'
  }
  return 'Netflix: 检测失败，请刷新面板'
}

async function checkYouTube() {
  const res = await request('https://www.youtube.com/premium')
  if (res.error || res.status !== 200) return 'YouTube: 检测失败，请刷新面板'
  if (res.body.includes('Premium is not available in your country')) return 'YouTube: 不支持解锁'
  const code = res.body.match(/"countryCode":"(.*?)"/)
  const region = code ? code[1].toUpperCase() : res.body.includes('www.google.cn') ? 'CN' : 'US'
  return 'YouTube: 已解锁 ➟ ' + region
}

async function checkDisney() {
  // 无需第三方 API 授权值；仅检查 Disney+ 官网地区信息及 CNBL。
  const res = await request('https://www.disneyplus.com/')
  if (res.error === 'timeout') return 'Disney+: 检测超时 🚦'
  if (res.error) return 'Disney+: 检测异常 ❌'
  if (res.status === 403 || res.status === 404 ||
      res.body.includes('Sorry, Disney+ is not available in your region.')) {
    return 'Disney+: 未支持 🚫'
  }
  if (res.status !== 200) return 'Disney+: 检测异常 ❌'
  const match = res.body.match(/Region: ([A-Za-z]{2})[\s\S]*?CNBL: ([12])/)
  if (!match) return 'Disney+: 网页可访问，解锁待确认'
  const region = match[1].toUpperCase()
  return match[2] === '2' ? 'Disney+: 即将登陆 ➟ ' + region : 'Disney+: 已解锁 ➟ ' + region
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
