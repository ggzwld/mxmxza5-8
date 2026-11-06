import { lazy, Suspense, useEffect, useRef, useState, type ReactNode } from "react";
import { Maximize, Pause, Play, Volume2, VolumeX } from "lucide-react";
import type MuxPlayerElement from "@mux/mux-player";
import { supabase } from "../lib/supabase";

const MuxPlayer = lazy(() => import("@mux/mux-player-react"));

const formatVideoTime = (time: number) => {
  const totalSeconds = Math.floor(Math.max(0, Number.isFinite(time) ? time : 0));
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = String(totalSeconds % 60).padStart(2, "0");
  return hours > 0
    ? `${hours}:${String(minutes).padStart(2, "0")}:${seconds}`
    : `${minutes}:${seconds}`;
};

interface MuxVideoPlayerProps {
  attachmentId?: string;
  filename?: string;
  initialPlaybackId?: string;
  initialAspectRatio?: number;
  initialVideoStatus?: string;
  controlsMode?: "default" | "minimal";
  presentation?: "default" | "immersive";
  overlay?: ReactNode;
  overlayOnlyOnMobilePortrait?: boolean;
  onAspectRatioChange?: (aspectRatio: number) => void;
}

export const MuxVideoPlayer: React.FC<MuxVideoPlayerProps> = ({
  attachmentId,
  filename,
  initialPlaybackId,
  initialAspectRatio,
  initialVideoStatus,
  controlsMode = "default",
  presentation = "default",
  overlay,
  overlayOnlyOnMobilePortrait = false,
  onAspectRatioChange,
}) => {
  const [playbackId, setPlaybackId] = useState<string | null>(initialPlaybackId ?? null);
  const [aspectRatio, setAspectRatio] = useState<number | null>(initialAspectRatio ?? null);
  const [viewportHeight, setViewportHeight] = useState(() => typeof window === "undefined" ? 0 : window.innerHeight);
  const [viewportWidth, setViewportWidth] = useState(() => typeof window === "undefined" ? 0 : window.innerWidth);
  const [isPlaying, setIsPlaying] = useState(false);
  const [isMuted, setIsMuted] = useState(false);
  const [volume, setVolume] = useState(1);
  const [duration, setDuration] = useState(0);
  const [currentTime, setCurrentTime] = useState(0);
  const [hasEnteredLoadRange, setHasEnteredLoadRange] = useState(false);
  const timeoutRef = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const isMountedRef = useRef(true);
  const muxPlayerRef = useRef<MuxPlayerElement | null>(null);
  const frameRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    const updateViewport = () => {
      setViewportHeight(window.innerHeight);
      setViewportWidth(window.innerWidth);
    };
    updateViewport();
    window.addEventListener("resize", updateViewport);
    return () => window.removeEventListener("resize", updateViewport);
  }, []);

  useEffect(() => {
    const frame = frameRef.current;
    if (!frame) return;

    const observer = new IntersectionObserver(([entry]) => {
      if (entry.isIntersecting) {
        setHasEnteredLoadRange(true);
        observer.disconnect();
      }
    }, { rootMargin: "1000px 0px" });

    observer.observe(frame);
    return () => observer.disconnect();
  }, []);

  useEffect(() => {
    if (!hasEnteredLoadRange) return;
    if (initialPlaybackId && initialAspectRatio && initialVideoStatus === "ready") return;

    isMountedRef.current = true;
    let retries = 0;

    const fetch = async () => {
      try {
        let nextPlaybackId: string | null = null;
        let status: string | null = null;

        if (attachmentId) {
          const response = await window.fetch(`/api/hotel-menu-video/${encodeURIComponent(attachmentId)}`, { cache: "no-store" });
          if (!response.ok) return;
          const video = await response.json() as { playbackId: string | null; status: string; aspectRatio: number | null };
          nextPlaybackId = video.playbackId;
          status = video.status;
          if (video.aspectRatio && Number.isFinite(video.aspectRatio) && video.aspectRatio > 0) {
            setAspectRatio(video.aspectRatio);
            onAspectRatioChange?.(video.aspectRatio);
          }
        } else if (filename) {
          const { data: video } = await supabase
            .from("video_uploads")
            .select("playback_id, status")
            .eq("filename", filename)
            .maybeSingle();
          nextPlaybackId = video?.playback_id || null;
          status = video?.status || null;
        }

        if (!isMountedRef.current) return;

        if (nextPlaybackId && status === "ready") {
          setPlaybackId(nextPlaybackId);
        } else if (
          attachmentId
            ? status !== "failed" && status !== "errored" && retries < 24
            : status === "processing" && retries < 3
        ) {
          retries++;
          timeoutRef.current = setTimeout(fetch, attachmentId ? 2500 : 1500);
        }
      } catch {
        if (isMountedRef.current && attachmentId && retries < 24) {
          retries++;
          timeoutRef.current = setTimeout(fetch, 2500);
        }
      }
    };

    fetch();

    return () => {
      isMountedRef.current = false;
      if (timeoutRef.current) clearTimeout(timeoutRef.current);
    };
  }, [attachmentId, filename, hasEnteredLoadRange, initialAspectRatio, initialPlaybackId, initialVideoStatus]);

  const isPortrait = aspectRatio !== null && aspectRatio < 1;
  const isImmersivePortrait = presentation === "immersive" && isPortrait;
  const isMobileImmersiveFrame = presentation === "immersive" && viewportWidth < 768;
  const frameStyle: React.CSSProperties = presentation === "immersive"
    ? isMobileImmersiveFrame || isImmersivePortrait
      ? { aspectRatio: aspectRatio ?? undefined, width: "100%", maxWidth: "100%" }
      : {
            aspectRatio: aspectRatio ?? undefined,
            width: "100%",
            maxHeight: "68svh",
            maxWidth: aspectRatio !== null ? `min(100%, calc(68svh * ${aspectRatio}))` : "100%",
          }
    : {
        aspectRatio: aspectRatio ?? undefined,
        width: isPortrait && aspectRatio !== null ? `${Math.min(448, viewportHeight * 0.7 * aspectRatio)}px` : "100%",
        maxHeight: "70svh",
        maxWidth: isPortrait ? "100%" : aspectRatio !== null ? `min(100%, calc(70svh * ${aspectRatio}))` : "100%",
      };
  const muxPlayerStyle = {
    width: "100%",
    height: "100%",
    "--media-object-fit": "contain",
    "--media-object-position": "50% 35%",
    "--controls": controlsMode === "minimal" ? "none" : undefined,
  } as React.CSSProperties & { [key: `--${string}`]: string | undefined };
  const isDesktopMinimalControls = controlsMode === "minimal" && viewportWidth >= 768;
  const isMobileMinimalControls = controlsMode === "minimal" && viewportWidth < 768;
  const frameClass = `${presentation === "immersive"
    ? "relative w-full overflow-hidden bg-black"
    : "relative mx-auto w-full overflow-hidden rounded-xl bg-black shadow-md"} ${isDesktopMinimalControls ? "group" : ""}`;
  const showOverlay = overlayOnlyOnMobilePortrait
    ? presentation === "immersive" && isPortrait && viewportWidth < 768
    : !(presentation === "immersive" && isPortrait && viewportWidth >= 768);

  const updateAspectRatio = (width: number, height: number) => {
    if (width <= 0 || height <= 0) return;
    const ratio = width / height;
    setAspectRatio(ratio);
    onAspectRatioChange?.(ratio);
  };

  const togglePlayback = () => {
    const media = muxPlayerRef.current;
    if (!media) return;
    if (media.paused) {
      void media.play().catch(() => setIsPlaying(false));
    } else {
      media.pause();
    }
  };

  const toggleMuted = () => {
    const media = muxPlayerRef.current;
    if (!media) return;
    media.muted = !media.muted;
    setIsMuted(media.muted);
  };

  const updateVolume = (nextVolume: number) => {
    setVolume(nextVolume);
    const media = muxPlayerRef.current;
    if (!media) return;
    media.volume = nextVolume;
    if (nextVolume > 0 && media.muted) media.muted = false;
    setIsMuted(media.muted);
  };

  const seekTo = (time: number) => {
    const media = muxPlayerRef.current;
    if (!media || !Number.isFinite(media.duration)) return;
    media.currentTime = time;
    setCurrentTime(time);
  };

  const toggleFullscreen = () => {
    if (document.fullscreenElement) {
      void document.exitFullscreen();
    } else {
      void frameRef.current?.requestFullscreen();
    }
  };

  const minimalControls = controlsMode === "minimal" && (
    <div className={`pointer-events-none absolute z-20 ${isDesktopMinimalControls || isMobileMinimalControls ? "inset-0" : "inset-x-0 top-0 flex items-start justify-between p-3"}`}>
      <button
        type="button"
        aria-label={isPlaying ? "Pause video" : "Play video"}
        onClick={togglePlayback}
        className={`pointer-events-auto flex items-center justify-center rounded-full bg-black/25 text-white shadow-sm backdrop-blur-sm transition duration-200 hover:bg-black/40 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-white ${isDesktopMinimalControls || isMobileMinimalControls ? `absolute left-1/2 top-1/2 h-14 w-14 -translate-x-1/2 -translate-y-1/2 ${isPlaying ? isDesktopMinimalControls ? "pointer-events-none opacity-0 group-hover:pointer-events-auto group-hover:opacity-100 focus-visible:pointer-events-auto focus-visible:opacity-100" : "pointer-events-none opacity-0" : "opacity-100"}` : "h-10 w-10"}`}
      >
        {isPlaying
          ? <Pause className="h-7 w-7" />
          : <Play className="ml-0.5 h-7 w-7" />}
      </button>
      <div className={`flex items-center gap-2 ${isDesktopMinimalControls || isMobileMinimalControls ? "absolute inset-x-0 top-0 justify-between p-3" : ""}`}>
        <div className="flex items-center gap-2">
          <button
            type="button"
            aria-label={isMuted ? "Unmute video" : "Mute video"}
            onClick={toggleMuted}
            className={`flex h-10 w-10 items-center justify-center rounded-full bg-black/25 text-white shadow-sm backdrop-blur-sm transition duration-200 hover:bg-black/40 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-white ${isDesktopMinimalControls ? "pointer-events-none opacity-0 group-hover:pointer-events-auto group-hover:opacity-100 focus-visible:pointer-events-auto focus-visible:opacity-100" : "pointer-events-auto"}`}
          >
            {isMuted ? <VolumeX className="h-5 w-5" /> : <Volume2 className="h-5 w-5" />}
          </button>
          {isDesktopMinimalControls && (
            <input
              type="range"
              min="0"
              max="1"
              step="0.01"
              value={volume}
              aria-label="Video volume"
              aria-valuetext={`${Math.round(volume * 100)}%`}
              onChange={(event) => updateVolume(Number(event.currentTarget.value))}
              className="pointer-events-none h-1 w-20 cursor-pointer accent-white opacity-0 transition-opacity duration-200 group-hover:pointer-events-auto group-hover:opacity-100 focus-visible:pointer-events-auto focus-visible:opacity-100"
            />
          )}
        </div>
        <button
          type="button"
          aria-label="View video fullscreen"
          onClick={toggleFullscreen}
          className={`flex h-10 w-10 items-center justify-center rounded-full bg-black/25 text-white shadow-sm backdrop-blur-sm transition duration-200 hover:bg-black/40 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-white ${isDesktopMinimalControls ? "pointer-events-none opacity-0 group-hover:pointer-events-auto group-hover:opacity-100 focus-visible:pointer-events-auto focus-visible:opacity-100" : "pointer-events-auto"}`}
        >
          <Maximize className="h-5 w-5" />
        </button>
      </div>
    </div>
  );

  return (
    <div
      ref={frameRef}
      className={frameClass}
      style={frameStyle}
      onClick={isDesktopMinimalControls || isMobileMinimalControls ? (event) => {
        if (event.target instanceof Element && event.target.closest("button, input")) return;
        togglePlayback();
      } : undefined}
    >
      {playbackId && hasEnteredLoadRange && (
        <Suspense fallback={null}>
          <MuxPlayer
            ref={muxPlayerRef}
            playbackId={playbackId}
            streamType="on-demand"
            onLoadedMetadata={(event) => {
              const video = event.currentTarget as typeof event.currentTarget & { videoWidth: number; videoHeight: number; muted: boolean; volume: number; duration: number };
              video.volume = volume;
              updateAspectRatio(video.videoWidth, video.videoHeight);
              setIsMuted(video.muted);
              setVolume(video.volume);
              if (Number.isFinite(video.duration)) setDuration(video.duration);
            }}
            onPlay={() => setIsPlaying(true)}
            onPause={() => setIsPlaying(false)}
            onEnded={() => {
              setIsPlaying(false);
              setCurrentTime(duration);
            }}
            onDurationChange={(event) => {
              const media = event.currentTarget as MuxPlayerElement;
              if (Number.isFinite(media.duration)) setDuration(media.duration);
            }}
            onTimeUpdate={(event) => setCurrentTime((event.currentTarget as MuxPlayerElement).currentTime)}
            onVolumeChange={(event) => {
              const media = event.currentTarget as MuxPlayerElement;
              setIsMuted(media.muted);
              setVolume(media.volume);
            }}
            style={muxPlayerStyle}
          />
        </Suspense>
      )}
      {(isDesktopMinimalControls || isMobileMinimalControls) && duration > 0 && (
        <>
          {isDesktopMinimalControls && (
            <div className="pointer-events-none absolute bottom-3 left-2 z-30 rounded bg-black/55 px-1.5 py-0.5 text-[10px] tabular-nums text-white/90 opacity-0 transition-opacity duration-200 group-hover:opacity-100 group-focus-within:opacity-100">
              {formatVideoTime(currentTime)} / {formatVideoTime(duration)}
            </div>
          )}
          <input
            type="range"
            min="0"
            max={duration}
            step="0.1"
            value={Math.min(currentTime, duration)}
            aria-label="Seek video"
            aria-valuetext={`${formatVideoTime(currentTime)} of ${formatVideoTime(duration)}`}
            onChange={(event) => seekTo(Number(event.currentTarget.value))}
            style={{
              backgroundImage: "linear-gradient(#fff, #fff), linear-gradient(rgba(255,255,255,0.35), rgba(255,255,255,0.35)), linear-gradient(rgba(0,0,0,0.9), rgba(0,0,0,0.9))",
              backgroundSize: `${(currentTime / duration) * 100}% 2px, 100% 2px, 100% 4px`,
              backgroundPosition: "left center, center, center",
              backgroundRepeat: "no-repeat",
            }}
            className={`absolute inset-x-0 bottom-0 z-30 h-3 w-full cursor-pointer appearance-none transition-[opacity,background-size] duration-200 focus-visible:outline-none [&::-webkit-slider-thumb]:h-2 [&::-webkit-slider-thumb]:w-2 [&::-webkit-slider-thumb]:appearance-none [&::-webkit-slider-thumb]:rounded-full [&::-webkit-slider-thumb]:bg-white [&::-moz-range-thumb]:h-2 [&::-moz-range-thumb]:w-2 [&::-moz-range-thumb]:appearance-none [&::-moz-range-thumb]:rounded-full [&::-moz-range-thumb]:border-0 [&::-moz-range-thumb]:bg-white ${isDesktopMinimalControls ? "pointer-events-none opacity-0 group-hover:pointer-events-auto group-hover:opacity-100 group-focus-within:pointer-events-auto group-focus-within:opacity-100" : "pointer-events-auto opacity-100"}`}
          />
        </>
      )}
      {minimalControls}
      {showOverlay && overlay}
    </div>
  );
};

export default MuxVideoPlayer;
