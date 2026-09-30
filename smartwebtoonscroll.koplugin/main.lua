-- Smart Webtoon Scroll 0.2.7.21 - Previous Chapter Last Smart Screen + Direct EOF + Symmetric Sidebar
-- Based on the integration/rendering ideas of Webtoon Helper 2.2.4.
-- Instead of detecting panels, every CBZ/CBR page is treated as part of one
-- continuous vertical strip. A page turn moves roughly one screen, then looks
-- around the target for a white/black separator and snaps just AFTER it.

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local Event = require("ui/event")
local LuaSettings = require("luasettings")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local StripOverlay = WidgetContainer:extend{ plugin = nil }
function StripOverlay:paintTo(bb, x, y)
    local P = self.plugin
    if not P or not P.is_enabled or not P.current_y then return end
    P:paintViewport(bb)
end

local SmartScroll = WidgetContainer:extend{
    name = "smart_webtoon_scroll",
    is_doc_only = true,
    is_enabled = true,

    -- Separator detection. Deliberately simple: no panel recognition.
    white_threshold = 245,
    white_ratio = 0.985,
    black_threshold = 14,
    black_ratio = 0.990,
    min_gap_px = 22,          -- native/source px minimum (before analysis scale)
    adaptive_gap_ratio = 0.006,
    analysis_max_width = 360,
    sample_width = 80,

    -- Navigation.
    search_range = 0.24,      -- +/- 24% of screen around nominal next boundary
    overlap_ratio = 0.035,    -- fallback overlap when a panel must be split
    min_advance_ratio = 0.58, -- never snap absurdly close to current top
    max_advance_ratio = 1.30,

    page_cache = {},
    render_cache = {},
    render_cache_order = {},
    preload_pending = false,
    preload_pages = 2,
    layout = nil,
    current_y = nil,
    overlay = nil,
    navigating = false,

    -- Webtoon Helper-style fit-to-height, deliberately limited:
    -- if the next separator is only a little below the screen, shrink the
    -- current slice just enough to show it completely.
    fit_to_height = true,
    fit_min_scale = 0.88, -- user setting: 12% maximum reduction
    fit_end = nil,
    fit_scale = 1.0,
    fit_at_page_end = false,
    fit_resume_y = nil,

    -- Optional right sidebar: narrows the webtoon render area on wide displays.
    sidebar_enabled = false,
    sidebar_ratio = 0.10,
}

function SmartScroll:readSettings()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/smart_webtoon_scroll.lua")
    local function n(k,d) return tonumber(self.settings:readSetting(k)) or d end
    self.is_enabled = self.settings:readSetting("is_enabled") ~= false
    self.white_threshold = n("white_threshold",245)
    self.white_ratio = n("white_ratio",0.985)
    self.black_threshold = n("black_threshold",14)
    self.black_ratio = n("black_ratio",0.990)
    self.min_gap_px = n("min_gap_px",22)
    self.adaptive_gap_ratio = n("adaptive_gap_ratio",0.006)
    self.search_range = n("search_range",0.24)
    self.overlap_ratio = n("overlap_ratio",0.035)
    self.fit_to_height = self.settings:readSetting("fit_to_height") ~= false
    self.fit_min_scale = n("fit_min_scale",0.88)
    self.preload_pages = math.max(0, math.min(10, math.floor(n("preload_pages",2))))
    self.sidebar_enabled = self.settings:readSetting("sidebar_enabled") == true
    self.sidebar_ratio = math.max(0.01, math.min(0.20, n("sidebar_ratio",0.10)))
end

function SmartScroll:saveSettings()
    for _,k in ipairs{
        "is_enabled","white_threshold","white_ratio","black_threshold","black_ratio",
        "min_gap_px","adaptive_gap_ratio","search_range","overlap_ratio","fit_to_height","fit_min_scale","preload_pages",
        "sidebar_enabled","sidebar_ratio"
    } do self.settings:saveSetting(k,self[k]) end
    self.settings:flush()
end

function SmartScroll:init()
    self:readSettings()
    Dispatcher:registerAction("smart_webtoon_next", {category="none", event="SmartWebtoonNext", title=_("Smart Webtoon: next screen"), paging=true})
    Dispatcher:registerAction("smart_webtoon_prev", {category="none", event="SmartWebtoonPrev", title=_("Smart Webtoon: previous screen"), paging=true})
    Dispatcher:registerAction("smart_webtoon_toggle", {category="none", event="SmartWebtoonToggle", title=_("Smart Webtoon: toggle"), paging=true})
end

function SmartScroll:pageCount()
    return (self.ui.document.info and self.ui.document.info.number_of_pages) or 1
end

-- Build the virtual strip in DISPLAY pixels. Every physical image is fit to
-- screen width independently, so pages with different source widths still join.
function SmartScroll:buildLayout()
    local full_sw = Screen:getWidth()
    local sw = self.sidebar_enabled and math.max(1, math.floor(full_sw * (1-self.sidebar_ratio) + 0.5)) or full_sw
    local pages, y = {}, 0
    for p=1,self:pageCount() do
        local d = self.ui.document:getNativePageDimensions(p)
        if d and d.w and d.h and d.w > 0 and d.h > 0 then
            local scale = sw / d.w
            local dh = math.max(1, math.floor(d.h * scale + 0.5))
            pages[#pages+1] = {page=p, native_w=d.w, native_h=d.h, scale=scale, y0=y, y1=y+dh, display_h=dh}
            y = y + dh
        end
    end
    self.layout = {pages=pages, total_h=y, screen_w=sw, full_screen_w=full_sw}
end

function SmartScroll:getPageLayout(page)
    if not self.layout then self:buildLayout() end
    for _,p in ipairs(self.layout.pages) do if p.page == page then return p end end
end

-- Analyze only horizontal blank bands. This is NOT panel detection.
function SmartScroll:analyzePage(page)
    if self.page_cache[page] then return self.page_cache[page] end
    local doc = self.ui.document
    local native = doc:getNativePageDimensions(page)
    if not native or native.w < 1 or native.h < 1 then return nil end
    local zoom = math.min(1, self.analysis_max_width / native.w)
    local ok,tile = pcall(function() return doc:renderPage(page,nil,zoom,0,1.0,1.0,true) end)
    if not ok or not tile or not tile.bb then return nil end
    local bb,aw,ah = tile.bb,tile.bb.w,tile.bb.h
    local sx = math.max(1,math.floor(aw/self.sample_width))
    local blank, white_rows, black_rows = {}, {}, {}
    for yy=0,ah-1 do
        local total, whites, blacks = 0,0,0
        for xx=0,aw-1,sx do
            local okp,px = pcall(function() return bb:getPixel(xx,yy):getColor8().a end)
            if okp and px then
                total=total+1
                if px >= self.white_threshold then whites=whites+1 end
                if px <= self.black_threshold then blacks=blacks+1 end
            end
        end
        local wr = total>0 and whites/total or 0
        local br = total>0 and blacks/total or 0
        blank[yy+1] = wr >= self.white_ratio or br >= self.black_ratio
        white_rows[yy+1], black_rows[yy+1] = wr, br
    end
    local native_gap = math.max(self.min_gap_px, math.floor(native.h*self.adaptive_gap_ratio+0.5))
    local min_gap = math.max(2, math.floor(native_gap*zoom+0.5))
    local gaps, yy = {}, 1
    while yy <= ah do
        if blank[yy] then
            local s = yy
            while yy <= ah and blank[yy] do yy=yy+1 end
            local e = yy-1
            if e-s+1 >= min_gap then
                -- source/native coordinates, end-exclusive-ish
                local n0 = math.max(0, math.floor((s-1)/zoom))
                local n1 = math.min(native.h, math.ceil(e/zoom))
                gaps[#gaps+1] = {y0=n0, y1=n1, h=n1-n0}
            end
        else yy=yy+1 end
    end
    local out = {native=native, gaps=gaps, zoom=zoom, white_rows=white_rows, black_rows=black_rows}
    self.page_cache[page] = out
    return out
end

-- Return all useful separator positions as GLOBAL DISPLAY Y coordinates.
-- We snap to the END of a blank band so the next screen starts with content,
-- not with a useless white/black separator at its top.
function SmartScroll:globalSeparatorsInRange(a,b)
    local out = {}
    if not self.layout then self:buildLayout() end
    for _,pl in ipairs(self.layout.pages) do
        if pl.y1 >= a and pl.y0 <= b then
            local an = self:analyzePage(pl.page)
            if an then
                for _,g in ipairs(an.gaps) do
                    local gs = pl.y0 + g.y0*pl.scale
                    local ge = pl.y0 + g.y1*pl.scale
                    if ge >= a and ge <= b then
                        out[#out+1] = {pos=ge, start=gs, finish=ge, gap_h=ge-gs, page=pl.page}
                    end
                end
            end
        end
    end
    return out
end

-- If a destination lands inside a white/black separator, advance only through
-- that contiguous blank area until real artwork starts. This reuses the cached
-- low-resolution row analysis; it does not render or analyze the page again.
-- It also works across physical CBZ image boundaries.
function SmartScroll:skipBlankAt(pos)
    if not self.layout then self:buildLayout() end
    local y=math.max(0,pos)
    local total=self.layout.total_h
    local started=false

    while y < total do
        local pl=nil
        for _,p in ipairs(self.layout.pages) do
            if y >= p.y0 and y < p.y1 then pl=p; break end
        end
        if not pl then break end

        local an=self:analyzePage(pl.page)
        if not an or not an.zoom or not an.white_rows then break end
        local native_y=(y-pl.y0)/pl.scale
        local row=math.floor(native_y*an.zoom)+1
        row=math.max(1,math.min(#an.white_rows,row))
        local wr=an.white_rows[row] or 0
        local br=an.black_rows[row] or 0
        local blank=(wr >= 0.94 or br >= 0.94)

        -- Never search for a separator here: only consume one when the exact
        -- destination is already inside it.
        if not blank then break end
        started=true

        local display_step=math.max(1,math.floor((1/an.zoom)*pl.scale+0.5))
        y=math.min(pl.y1,y+display_step)
        -- y == pl.y1 naturally enters the following physical image next loop.
    end

    if started and y > pos then
        y=math.max(pos,y-Screen:scaleBySize(3))
    end
    return y
end

function SmartScroll:findBestSnap(target, direction)
    local sh = Screen:getHeight()
    local radius = sh * self.search_range
    local cur = self.current_y or 0
    local minpos, maxpos
    if direction > 0 then
        minpos = math.max(cur + sh*self.min_advance_ratio, target-radius)
        maxpos = math.min(cur + sh*self.max_advance_ratio, target+radius)
    else
        -- For backwards navigation target is an estimated previous top.
        minpos = math.max(0, target-radius)
        maxpos = math.min(cur - sh*0.40, target+radius)
    end
    if maxpos <= minpos then return nil end
    local gaps = self:globalSeparatorsInRange(minpos,maxpos)
    local best,bestscore
    for _,g in ipairs(gaps) do
        local dist = math.abs(g.pos-target) / math.max(1,radius)
        local bonus = math.min(0.30, g.gap_h / math.max(1,sh) * 2.0)
        local score = dist - bonus
        if not bestscore or score < bestscore then best,bestscore=g,score end
    end
    return best
end

-- Webtoon Helper-style *single* feature: fit the current slice to height.
-- We do not restore panel segmentation. We simply look for the first strict
-- separator a little below the normal screen bottom. If it can be reached with
-- only a modest reduction, that whole slice is rendered on the current screen.
function SmartScroll:updateFitToHeight()
    self.fit_end=nil; self.fit_scale=1.0; self.fit_at_page_end=false; self.fit_resume_y=nil
    if not self.fit_to_height or not self.current_y or not self.layout then return end

    local sh=Screen:getHeight()

    -- D7: one-shot suppression used only when leaving a fitted slice.
    -- The current fitted screen keeps its fit.  On the following Next, the
    -- destination is committed at the end of the cached separator and this
    -- single fit recalculation is suppressed, preventing the destination from
    -- immediately growing a new fit across that separator.  The flag is
    -- consumed here, so all later navigation uses the normal fit logic again.
    if self.suppress_next_fit_update then
        self.suppress_next_fit_update=nil
        self.fit_boundary_lock=self.suppress_fit_gap
        self.suppress_fit_gap=nil
        return
    end
    self.fit_boundary_lock=nil

    local normal_bottom=self.current_y+sh
    local furthest=self.current_y + sh/self.fit_min_scale

    -- Important: do not fit when the normal bottom already lands inside a
    -- separator. In that case the normal 0.2 snap/trim logic is already ideal.
    local around=self:globalSeparatorsInRange(normal_bottom-sh*0.015, normal_bottom+sh*0.015)
    for _,g in ipairs(around) do
        if normal_bottom >= g.start and normal_bottom <= g.finish then return end
    end

    -- Find the FIRST safe content boundary only a little below the viewport.
    -- A boundary may be either:
    --   1) the START of a detected white/black separator, or
    --   2) the END of a physical CBZ/CBR image.
    -- The second case is important for webtoons whose individual image file is
    -- just a little taller than the screen and has no detectable separator at
    -- its bottom: it can now be reduced to fit completely instead of split.
    local scan_end=math.min(self.layout.total_h, furthest + sh)
    local content_end=nil
    local content_end_is_page=false
    local content_resume=nil

    local gaps=self:globalSeparatorsInRange(normal_bottom+1, scan_end)
    for _,g in ipairs(gaps) do
        local candidate=g.start
        if candidate > normal_bottom and candidate <= furthest
           and (not content_end or candidate < content_end) then
            content_end=candidate
            content_end_is_page=false
            content_resume=g.finish
        end
    end

    -- D8: a physical CBZ image boundary is NOT automatically a panel end.
    -- If the next image starts with artwork, the panel is continuous across
    -- files and only a real cached white/black separator may end the fit.
    -- Keep the old page-end fit only for the final image, or when the first
    -- analysed row of the following image is itself blank.
    for i,pl in ipairs(self.layout.pages) do
        local candidate=pl.y1
        if candidate > normal_bottom and candidate <= furthest
           and (not content_end or candidate < content_end) then
            local safe_page_end = (i == #self.layout.pages)
            if not safe_page_end then
                local nextpl=self.layout.pages[i+1]
                local an=nextpl and self:analyzePage(nextpl.page) or nil
                if an and an.white_rows and #an.white_rows > 0 then
                    local wr=an.white_rows[1] or 0
                    local br=(an.black_rows and an.black_rows[1]) or 0
                    safe_page_end=(wr >= 0.94 or br >= 0.94)
                end
            end
            if safe_page_end then
                content_end=candidate
                content_end_is_page=true
                content_resume=candidate
            end
        end
    end

    if not content_end then return end
    local span=content_end-self.current_y
    local scale=math.min(1.0, sh/math.max(1,span))
    if scale >= self.fit_min_scale and scale < 0.999 then
        -- Render only through the end of the current content. On Next, resume
        -- after the triggering separator (or at the physical image boundary).
        self.fit_end=content_end
        self.fit_scale=scale
        self.fit_at_page_end=content_end_is_page
        self.fit_resume_y=content_resume or content_end
    end
end

function SmartScroll:syncUnderlyingPage()
    if not self.layout then return end
    local y = self.current_y or 0
    local page = 1
    for _,pl in ipairs(self.layout.pages) do
        if y >= pl.y0 and y < pl.y1 then page=pl.page; break end
        if y >= pl.y1 then page=pl.page end
    end
    if self.ui.paging and self.ui.paging.current_page ~= page then
        self.navigating=true
        self.ui.paging:onGotoPage(page)
        self.navigating=false
    end
end

function SmartScroll:setY(y)
    if not self.layout then self:buildLayout() end
    local maxy = math.max(0,self.layout.total_h-Screen:getHeight())
    self.current_y = math.max(0,math.min(maxy,math.floor(y+0.5)))
    self:syncUnderlyingPage()
    self:updateFitToHeight()
    UIManager:setDirty(self.ui.view.dialog,"full")
    self:schedulePreload()
end

function SmartScroll:nextScreen()
    if not self.current_y then self.current_y=0 end
    local sh=Screen:getHeight()
    local maxy=math.max(0,self.layout.total_h-sh)

    -- At the real end of the virtual strip, emit KOReader's EndOfBook
    -- event directly. ReaderPaging normally emits this only after a native
    -- page turn fails to move; doing it here avoids consuming an extra tap.
    if self.current_y >= maxy-1 and not (self.fit_end and self.fit_end > self.current_y) then
        if self.ui then
            self.ui:handleEvent(Event:new("EndOfBook"))
            return true
        end
        return false
    end

    local ny
    if self.fit_end and self.fit_end > self.current_y then
        -- Preserve the fit that rendered the current screen. Resume after the
        -- separator that ended it, then suppress exactly one destination fit
        -- recalculation so the following panel starts cleanly at the top.
        local resume=self.fit_resume_y or self.fit_end
        ny=self:skipBlankAt(resume)

        local near=self:globalSeparatorsInRange(self.fit_end-sh*0.03,ny+sh*0.03)
        local best=nil
        for _,g in ipairs(near) do
            if g.start <= self.fit_end+Screen:scaleBySize(4)
               and g.finish >= self.fit_end-Screen:scaleBySize(4) then
                best=g; break
            end
            if g.finish <= ny+Screen:scaleBySize(4) then
                if not best or math.abs(g.finish-ny) < math.abs(best.finish-ny) then best=g end
            end
        end
        self.suppress_next_fit_update=true
        self.suppress_fit_gap=best
    else
        local target=self.current_y+sh
        local snap=self:findBestSnap(target,1)
        if snap then
            ny=snap.pos
        else
            ny=self.current_y + sh*(1-self.overlap_ratio)
        end
        ny=self:skipBlankAt(ny)
    end

    self:setY(ny)
    return true
end

function SmartScroll:openPreviousAtEnd()
    if not self.ui or not self.ui.document then return false end
    local FileChooser = require("ui/widget/filechooser")
    local fc = FileChooser:new{ ui = self.ui }
    local file = fc:getNextOrPreviousFileInFolder(self.ui.document.file, true)
    if not file then
        UIManager:show(InfoMessage:new{ text=_("This is the first file in the folder. No previous file to open.") })
        return true
    end

    -- Remember the exact destination. The new Reader instance consumes this
    -- one-shot marker and positions Smart Webtoon Scroll at its real EOF.
    G_reader_settings:saveSetting("smart_webtoon_open_at_end", file)
    G_reader_settings:flush()
    local filemanagerutil = require("apps/filemanager/filemanagerutil")
    UIManager:nextTick(function()
        filemanagerutil.openFile(self.ui, file)
    end)
    return true
end

function SmartScroll:prevScreen()
    if not self.current_y or self.current_y <= 0 then
        self:setY(0)
        return self:openPreviousAtEnd()
    end
    local sh=Screen:getHeight()
    local target=self.current_y-sh
    local snap=self:findBestSnap(target,-1)
    local ny=snap and snap.pos or (self.current_y-sh*(1-self.overlap_ratio))
    self:setY(ny); return true
end

function SmartScroll:onSmartWebtoonNext() return self:nextScreen() end
function SmartScroll:onSmartWebtoonPrev() return self:prevScreen() end
function SmartScroll:onSmartWebtoonToggle()
    self.is_enabled=not self.is_enabled; self:saveSettings()
    if self.is_enabled then self:resetAtPage(self.ui.paging.current_page or 1) else UIManager:setDirty(self.ui.view.dialog,"full") end
    return true
end

function SmartScroll:renderCacheKey(page, scale)
    return tostring(page) .. "@" .. string.format("%.5f", scale)
end

function SmartScroll:getRenderedPage(page, scale)
    local key=self:renderCacheKey(page,scale)
    local cached=self.render_cache[key]
    if cached and cached.bb then return cached end
    local ok,tile=pcall(function()
        return self.ui.document:renderPage(page,nil,scale,0,1.0,1.0,true)
    end)
    if not ok or not tile or not tile.bb then return nil end
    self.render_cache[key]=tile
    self.render_cache_order[#self.render_cache_order+1]=key
    local max_cache=math.max(2,self.preload_pages+1)
    while #self.render_cache_order > max_cache do
        local old=table.remove(self.render_cache_order,1)
        if old ~= key then self.render_cache[old]=nil end
    end
    return tile
end

function SmartScroll:fitSideColor(srcbb, sy, hh)
    if not srcbb or srcbb.w < 2 or srcbb.h < 1 then return Blitbuffer.COLOR_WHITE end
    local y0=math.max(0,sy)
    local y1=math.min(srcbb.h-1,sy+hh-1)
    if y1 < y0 then return Blitbuffer.COLOR_WHITE end
    local step=math.max(1,math.floor((y1-y0+1)/24))
    local inset=math.min(2,math.max(0,math.floor(srcbb.w/100)))
    local xs={inset, math.max(0,srcbb.w-1-inset)}
    local sum,n=0,0
    for yy=y0,y1,step do
        for _,xx in ipairs(xs) do
            local ok,px=pcall(function() return srcbb:getPixel(xx,yy):getColor8().a end)
            if ok and px then sum=sum+px; n=n+1 end
        end
    end
    if n>0 and (sum/n) < 128 then return Blitbuffer.COLOR_BLACK end
    return Blitbuffer.COLOR_WHITE
end

function SmartScroll:schedulePreload()
    if self.preload_pages <= 0 or self.preload_pending or not self.layout or not self.current_y then return end
    self.preload_pending=true
    UIManager:scheduleIn(0.08,function()
        self.preload_pending=false
        if not self.is_enabled or not self.layout or not self.current_y then return end
        local sh=Screen:getHeight()
        local probe=(self.fit_resume_y or self.fit_end or (self.current_y+sh)) + Screen:scaleBySize(2)
        local first=nil
        for i,pl in ipairs(self.layout.pages) do
            if pl.y1 > probe then first=i; break end
        end
        if not first then return end
        local last=math.min(#self.layout.pages,first+self.preload_pages-1)
        for i=first,last do
            local pl=self.layout.pages[i]
            self:getRenderedPage(pl.page,pl.scale)
        end
    end)
end

function SmartScroll:paintViewport(bb)
    if not self.layout then self:buildLayout() end
    local full_sw,sh=Screen:getWidth(),Screen:getHeight()
    local sw=(self.layout and self.layout.screen_w) or full_sw
    -- Sidebar ratio is TOTAL reserved width, split equally left/right.
    local content_x=math.floor((full_sw-sw)/2)
    bb:paintRect(0,0,full_sw,sh,Blitbuffer.COLOR_WHITE)

    local f=(self.fit_end and self.fit_scale) or 1.0
    local top=self.current_y
    local bottom=self.fit_end or (self.current_y+sh)
    local dy=0

    for _,pl in ipairs(self.layout.pages) do
        if pl.y1 > top and pl.y0 < bottom then
            local vis0=math.max(top,pl.y0)
            local vis1=math.min(bottom,pl.y1)
            -- Render the physical CBZ image at its normal fit-to-width scale,
            -- multiplied by the tiny fit-to-height factor.
            local render_scale=pl.scale*f
            local tile=self:getRenderedPage(pl.page,render_scale)
            if tile and tile.bb then
                -- vis0/vis1 are in normal strip display coordinates; convert
                -- their page-relative positions to the reduced render.
                local sy=math.max(0,math.floor((vis0-pl.y0)*f+0.5))
                local hh=math.max(1,math.floor((vis1-vis0)*f+0.5))
                hh=math.min(hh,tile.bb.h-sy,sh-dy)
                local ww=math.min(sw,tile.bb.w)
                if hh>0 and ww>0 then
                    local inner_dx=math.floor((sw-ww)/2)
                    local dx=content_x+inner_dx
                    if f < 0.999 and inner_dx > 0 then
                        local side_color=self:fitSideColor(tile.bb,sy,hh)
                        bb:paintRect(content_x,dy,inner_dx,hh,side_color)
                        bb:paintRect(dx+ww,dy,sw-(inner_dx+ww),hh,side_color)
                    end
                    bb:blitFrom(tile.bb,dx,dy,0,sy,ww,hh)
                    dy=dy+hh
                end
            end
        end
        if dy>=sh then break end
    end
end

function SmartScroll:resetAtPage(page)
    self:buildLayout()
    self.page_cache={}
    self.render_cache={}
    self.render_cache_order={}
    local pl=self:getPageLayout(page)
    self.current_y=pl and pl.y0 or 0
    -- If the physical image itself starts inside a separator, start at content.
    self.current_y=self:skipBlankAt(self.current_y)
    self:updateFitToHeight()
    UIManager:setDirty(self.ui.view.dialog,"full")
    self:schedulePreload()
end

function SmartScroll:hookPageTurns()
    if self._orig_goto_rel or not self.ui.paging then return end
    local plugin=self
    self._orig_goto_rel=self.ui.paging.onGotoViewRel
    self.ui.paging.onGotoViewRel=function(paging,diff,...)
        if plugin.is_enabled and not plugin.navigating and (diff==1 or diff==-1) then
            local handled
            if diff==1 then handled=plugin:nextScreen() else handled=plugin:prevScreen() end
            if handled then return true end
        end
        return plugin._orig_goto_rel(paging,diff,...)
    end
end
function SmartScroll:unhookPageTurns()
    if self._orig_goto_rel and self.ui and self.ui.paging then self.ui.paging.onGotoViewRel=self._orig_goto_rel end
    self._orig_goto_rel=nil
end

function SmartScroll:onReaderReady()
    self.ui.menu:registerToMainMenu(self)
    if not self.ui.paging or not self.ui.document or self.ui.document.is_reflowable then return end
    self:buildLayout()
    self.overlay=StripOverlay:new{plugin=self}
    self.ui.view:registerViewModule("smart_webtoon_scroll",self.overlay)
    self:hookPageTurns()
    if self.is_enabled then
        local open_at_end = G_reader_settings:readSetting("smart_webtoon_open_at_end")
        if open_at_end and open_at_end == self.ui.document.file then
            -- One-shot: clear before positioning, so a crash/reopen cannot
            -- unexpectedly force this document back to its end.
            G_reader_settings:delSetting("smart_webtoon_open_at_end")
            G_reader_settings:flush()
            self.page_cache={}
            self.render_cache={}
            self.render_cache_order={}
            local maxy=math.max(0,self.layout.total_h-Screen:getHeight())
            self:setY(maxy)
        else
            self:resetAtPage(self.ui.paging.current_page or 1)
        end
    end
end

function SmartScroll:onPageUpdate(page)
    if self.navigating or not self.is_enabled then return end
    local pl=self:getPageLayout(page)
    if pl and (not self.current_y or self.current_y<pl.y0-Screen:getHeight() or self.current_y>pl.y1) then
        self:resetAtPage(page)
    end
end

function SmartScroll:showSettingsDialog(menu)
    local dlg
    local fit_reduction=math.floor((1-self.fit_min_scale)*1000+0.5)/10
    dlg=MultiInputDialog:new{title=_("Smart Webtoon Scroll"),fields={
        {
            description=_("Flexible search range (%)\nHow far around the normal page boundary to look for a white/black separator."),
            text=tostring(math.floor(self.search_range*100+0.5)),input_type="number",hint=_("Recommended: 24"),
        },
        {
            description=_("Long-panel overlap (%)\nOverlap kept when content is too long to fit and must be split."),
            text=tostring(math.floor(self.overlap_ratio*1000+0.5)/10),input_type="number",hint=_("Recommended: 3.5"),
        },
        {
            description=_("Minimum separator height (px)\nMinimum source-image height for a white/black band to count as a separator."),
            text=tostring(self.min_gap_px),input_type="number",hint=_("Recommended: 22"),
        },
        {
            description=_("White threshold (0-255)\nHigher values require separator pixels to be closer to pure white."),
            text=tostring(self.white_threshold),input_type="number",hint=_("Recommended: 245"),
        },
        {
            description=_("Max Fit-to-Height reduction (%)\nIf content or an image is only slightly taller than the screen, shrink it by at most this percentage so it fits completely. 0 disables shrinking."),
            text=tostring(fit_reduction),input_type="number",hint=_("Recommended: 12"),
        },
        {
            description=_("Preload pages\nNumber of following CBZ images to render in advance. 0 disables preloading."),
            text=tostring(self.preload_pages),input_type="number",hint=_("Recommended: 2"),
        },
        {
            description=_("Sidebar width (%)\nTotal blank sidebar width, split equally between left and right. Range: 1-20%."),
            text=tostring(math.floor(self.sidebar_ratio*100+0.5)),input_type="number",hint=_("Recommended: 10"),
        },
    },buttons={{{text=_("Cancel"),callback=function() UIManager:close(dlg) end},{text=_("Save"),callback=function()
        local f=dlg:getFields()
        self.search_range=math.max(.05,math.min(.45,(tonumber(f[1]) or 24)/100))
        self.overlap_ratio=math.max(0,math.min(.15,(tonumber(f[2]) or 3.5)/100))
        self.min_gap_px=math.max(2,tonumber(f[3]) or 22)
        self.white_threshold=math.max(0,math.min(255,tonumber(f[4]) or 245))
        local reduction=math.max(0,math.min(80,tonumber(f[5]) or 12))
        self.fit_min_scale=1-(reduction/100)
        self.fit_to_height=reduction>0
        self.preload_pages=math.max(0,math.min(10,math.floor(tonumber(f[6]) or 2)))
        self.sidebar_ratio=math.max(0.01,math.min(0.20,(tonumber(f[7]) or 10)/100))
        self.page_cache={}; self.render_cache={}; self:saveSettings(); self:buildLayout(); self:resetAtPage(self.ui.paging.current_page or 1); UIManager:close(dlg)
        if menu then menu:updateItems() end
        UIManager:setDirty(self.ui.view.dialog,"full")
    end}}}}
    UIManager:show(dlg); dlg:onShowKeyboard()
end

function SmartScroll:addToMainMenu(menu_items)
    menu_items.SmartWebtoonScroll={text=_("Smart Webtoon Scroll"),sorting_hint="typeset",sub_item_table={
        {text=_("Enable continuous strip"),checked_func=function() return self.is_enabled end,callback=function() self:onSmartWebtoonToggle() end},
        {text=_("Fit slightly oversized content to height"),checked_func=function() return self.fit_to_height end,callback=function() self.fit_to_height=not self.fit_to_height; self:saveSettings(); self:updateFitToHeight(); UIManager:setDirty(self.ui.view.dialog,"full") end},
        {text=_("Sidebar"),checked_func=function() return self.sidebar_enabled end,callback=function() self.sidebar_enabled=not self.sidebar_enabled; self:saveSettings(); self:resetAtPage(self.ui.paging.current_page or 1) end},
        {text=_("Next smart screen"),callback=function() self:nextScreen() end},
        {text=_("Previous smart screen"),callback=function() self:prevScreen() end},
        {text=_("Scroll settings"),callback=function(m) self:showSettingsDialog(m) end},
        {text=_("Reset at current CBZ image"),callback=function() self:resetAtPage(self.ui.paging.current_page or 1) end},
        {text=_("About"),keep_menu_open=true,callback=function() UIManager:show(InfoMessage:new{text=_("Smart Webtoon Scroll treats the whole CBZ/CBR as one continuous vertical strip. Page turns use a flexible range to land just after nearby white or black separator bands. It does not try to recognize panels. If content or a physical image is only slightly taller than the screen, Fit-to-Height can shrink it up to the user-defined maximum reduction so it is shown completely; every forward destination that already lands inside a white/black separator skips only that contiguous blank area and starts at the first real content. If no safe separator exists, it splits the long panel with a small overlap.")}) end},
    }}
end

function SmartScroll:onCloseDocument()
    self:unhookPageTurns(); self.current_y=nil; self.page_cache={}; self.render_cache={}; self.layout=nil
    if self.ui and self.ui.view and self.ui.view.view_modules then self.ui.view.view_modules.smart_webtoon_scroll=nil end
end

return SmartScroll
