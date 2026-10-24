const invoke = window.__TAURI__.core.invoke;
const convertFileSrc = window.__TAURI__.core.convertFileSrc;

const listEl = document.getElementById('track-list');
const countEl = document.getElementById('track-count');
const emptyEl = document.getElementById('empty-state');
const playButton = document.getElementById('play-button');
const prevButton = document.getElementById('prev-button');
const nextButton = document.getElementById('next-button');
const repeatButton = document.getElementById('repeat-button');
const npTitle = document.getElementById('np-title');
const npArtist = document.getElementById('np-artist');
const seekBar = document.getElementById('seek-bar');
const volumeBar = document.getElementById('volume-bar');
const positionEl = document.getElementById('position');
const durationEl = document.getElementById('duration');
const contextMenu = document.getElementById('context-menu');

let tracks = [];
let libraryRoot = '';
let currentId = null;
let currentDuration = 0;
let draggingSeek = false;
let draggingVolume = false;
let repeatMode = 'off';
let menuTrackId = null;

function formatTime(seconds) {
    if (!Number.isFinite(seconds) || seconds < 0) return '0:00';
    const total = Math.floor(seconds);
    return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, '0')}`;
}

async function boot() {
    libraryRoot = await invoke('library_root_info');
    tracks = await invoke('list_tracks');
    await invoke('set_queue', { ids: tracks.map((track) => track.id) });
    render();
    document.title = `Voanisa · ${tracks.length} 首`;
}

function render() {
    listEl.replaceChildren();
    countEl.textContent = tracks.length ? `${tracks.length} 首` : '';
    emptyEl.hidden = tracks.length > 0;

    for (const track of tracks) {
        const row = document.createElement('li');
        row.className = 'track-row';
        row.dataset.id = track.id;

        const cover = track.cover_file_name
            ? document.createElement('img')
            : document.createElement('div');
        cover.className = 'track-cover';
        if (track.cover_file_name) {
            // Rendered covers live next to the library database; the asset
            // protocol reads them straight from disk, so no base64 over IPC.
            cover.src = convertFileSrc(
                `${libraryRoot}/Covers/Rendered/${track.cover_file_name}`
            );
            cover.alt = '';
            cover.loading = 'lazy';
        }

        const text = document.createElement('div');
        const title = document.createElement('span');
        title.className = 'track-title';
        title.textContent = track.title;
        const artist = document.createElement('span');
        artist.className = 'track-artist';
        artist.textContent = track.artist || '—';
        text.append(title, artist);

        const time = document.createElement('span');
        time.className = 'track-duration';
        time.textContent = formatTime(track.duration);

        row.append(cover, text, time);
        row.addEventListener('dblclick', () => play(track.id));
        row.addEventListener('contextmenu', (event) => {
            event.preventDefault();
            openMenu(event.clientX, event.clientY, track.id);
        });
        listEl.append(row);
    }
}

function showNowPlaying(id) {
    const track = tracks.find((item) => item.id === id);
    npTitle.textContent = track ? track.title : '未在播放';
    npArtist.textContent = track ? track.artist || '' : '';
    for (const row of listEl.children) {
        row.classList.toggle('is-playing', row.dataset.id === id);
    }
}

async function play(id) {
    await invoke('play_track', { id });
    currentId = id;
    showNowPlaying(id);
}

async function skip(offset) {
    await invoke('play_offset', { offset });
}

/* ---------- 右键菜单 ---------- */

function openMenu(x, y, id) {
    menuTrackId = id;
    contextMenu.hidden = false;
    const width = contextMenu.offsetWidth;
    const height = contextMenu.offsetHeight;
    contextMenu.style.left = `${Math.min(x, window.innerWidth - width - 8)}px`;
    contextMenu.style.top = `${Math.min(y, window.innerHeight - height - 8)}px`;
}

function closeMenu() {
    contextMenu.hidden = true;
    menuTrackId = null;
}

contextMenu.addEventListener('click', async (event) => {
    const action = event.target.dataset.action;
    const id = menuTrackId;
    closeMenu();
    if (!action || !id) return;
    if (action === 'play') {
        await play(id);
    } else if (action === 'reveal') {
        await invoke('reveal_track', { id });
    }
});

window.addEventListener('pointerdown', (event) => {
    if (!contextMenu.hidden && !contextMenu.contains(event.target)) closeMenu();
});
window.addEventListener('blur', closeMenu);

/* ---------- 播放条 ---------- */

playButton.addEventListener('click', async () => {
    const playing = await invoke('toggle_play');
    playButton.classList.toggle('is-playing', playing);
});

prevButton.addEventListener('click', () => skip(-1));
nextButton.addEventListener('click', () => skip(1));

repeatButton.addEventListener('click', async () => {
    repeatMode = await invoke('cycle_repeat');
    paintRepeat();
});

function paintRepeat() {
    repeatButton.classList.toggle('is-on', repeatMode !== 'off');
    repeatButton.classList.toggle('is-one', repeatMode === 'one');
    repeatButton.title = repeatMode === 'off' ? '循环：关' : repeatMode === 'all' ? '循环：列表' : '循环：单曲';
}

seekBar.addEventListener('input', () => {
    draggingSeek = true;
    positionEl.textContent = formatTime((Number(seekBar.value) / 1000) * currentDuration);
});

seekBar.addEventListener('change', async () => {
    const seconds = (Number(seekBar.value) / 1000) * currentDuration;
    await invoke('seek', { seconds });
    draggingSeek = false;
});

volumeBar.addEventListener('input', () => {
    draggingVolume = true;
    invoke('set_volume', { volume: Number(volumeBar.value) / 100 });
});
volumeBar.addEventListener('change', () => {
    draggingVolume = false;
});

document.addEventListener('keydown', async (event) => {
    const target = event.target;
    if (target instanceof HTMLInputElement) return;

    if (event.code === 'Space') {
        event.preventDefault();
        const playing = await invoke('toggle_play');
        playButton.classList.toggle('is-playing', playing);
    } else if (event.key === 'ArrowRight' && event.altKey) {
        await skip(1);
    } else if (event.key === 'ArrowLeft' && event.altKey) {
        await skip(-1);
    }
});

setInterval(async () => {
    let state;
    try {
        state = await invoke('status');
    } catch {
        return;
    }

    playButton.classList.toggle('is-playing', state.playing);
    currentDuration = state.duration;

    if (!draggingSeek) {
        positionEl.textContent = formatTime(state.position);
        durationEl.textContent = formatTime(state.duration);
        seekBar.value = state.duration > 0
            ? String(Math.round((state.position / state.duration) * 1000))
            : '0';
    }

    if (!draggingVolume) {
        volumeBar.value = String(Math.round(state.volume * 100));
    }

    if (state.repeat !== repeatMode) {
        repeatMode = state.repeat;
        paintRepeat();
    }

    if (state.track_id !== currentId) {
        currentId = state.track_id;
        showNowPlaying(currentId);
    }
}, 250);

paintRepeat();

boot().catch((error) => {
    npTitle.textContent = '加载失败';
    npArtist.textContent = String(error);
    document.title = 'Voanisa · 加载失败';
    console.error(error);
});
