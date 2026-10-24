const invoke = window.__TAURI__.core.invoke;
const convertFileSrc = window.__TAURI__.core.convertFileSrc;

const listEl = document.getElementById('track-list');
const countEl = document.getElementById('track-count');
const emptyEl = document.getElementById('empty-state');
const playButton = document.getElementById('play-button');
const npTitle = document.getElementById('np-title');
const npArtist = document.getElementById('np-artist');
const seekBar = document.getElementById('seek-bar');
const positionEl = document.getElementById('position');
const durationEl = document.getElementById('duration');

let tracks = [];
let libraryRoot = '';
let currentId = null;
let currentDuration = 0;
let draggingSeek = false;

function formatTime(seconds) {
    if (!Number.isFinite(seconds) || seconds < 0) return '0:00';
    const total = Math.floor(seconds);
    return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, '0')}`;
}

async function boot() {
    libraryRoot = await invoke('library_root_info');
    tracks = await invoke('list_tracks');
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
        listEl.append(row);
    }
}

async function play(id) {
    await invoke('play_track', { id });
    currentId = id;
    const track = tracks.find((item) => item.id === id);
    npTitle.textContent = track ? track.title : '';
    npArtist.textContent = track ? track.artist || '' : '';
    highlight();
}

function highlight() {
    for (const row of listEl.children) {
        row.classList.toggle('is-playing', row.dataset.id === currentId);
    }
}

playButton.addEventListener('click', async () => {
    const playing = await invoke('toggle_play');
    playButton.textContent = playing ? '❚❚' : '▶';
});

seekBar.addEventListener('input', () => {
    draggingSeek = true;
    const seconds = (Number(seekBar.value) / 1000) * currentDuration;
    positionEl.textContent = formatTime(seconds);
});

seekBar.addEventListener('change', async () => {
    const seconds = (Number(seekBar.value) / 1000) * currentDuration;
    await invoke('seek', { seconds });
    draggingSeek = false;
});

setInterval(async () => {
    let state;
    try {
        state = await invoke('status');
    } catch {
        return;
    }

    playButton.textContent = state.playing ? '❚❚' : '▶';
    currentDuration = state.duration;

    if (!draggingSeek) {
        positionEl.textContent = formatTime(state.position);
        durationEl.textContent = formatTime(state.duration);
        seekBar.value = state.duration > 0
            ? String(Math.round((state.position / state.duration) * 1000))
            : '0';
    }

    if (state.track_id !== currentId) {
        currentId = state.track_id;
        const track = tracks.find((item) => item.id === currentId);
        npTitle.textContent = track ? track.title : '未在播放';
        npArtist.textContent = track ? track.artist || '' : '';
        highlight();
    }
}, 250);

boot().catch((error) => {
    npTitle.textContent = '加载失败';
    npArtist.textContent = String(error);
    document.title = `Voanisa · 加载失败`;
    console.error(error);
});
