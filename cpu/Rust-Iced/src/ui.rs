use iced::widget::{column, container, image, row, stack, text};
use iced::{Alignment, Background, Border, Color, Element, Length};
use std::sync::atomic::Ordering;
use crate::decoder::StreamSlot;
use crate::telemetry::FpsStreamSeconds;

#[derive(Debug, Clone)]
pub enum Message {
    RenderTick,
    TelemetryTick,
}

pub struct HudState {
    pub machine_id: String,
    pub active_streams: usize,
    pub total_streams: usize,
    pub tick_in_window: u32,
    pub window_duration: u32,
    pub total_flushes: u64,
    pub current_buckets: FpsStreamSeconds,
    pub stream_fps: Vec<u32>,
    pub total_fps: u32,
    pub avg_fps: f32,
    pub log_path: String,
}

pub fn view_hud<'a>(hud: &'a HudState) -> Element<'a, Message> {
    let title_text = text("6-Hour RTSP 30-Stream Video Grid Benchmark")
        .size(15)
        .color(Color::from_rgb8(240, 240, 245));

    let badge_framework = make_badge("Rust Iced CPU", Color::from_rgb8(45, 110, 240));
    let badge_backend = make_badge("tiny-skia", Color::from_rgb8(34, 160, 90));
    let badge_simd = make_badge("SIMD YUV->RGBA", Color::from_rgb8(140, 70, 210));
    let badge_arcswap = make_badge("Lock-Free ArcSwap", Color::from_rgb8(210, 130, 20));

    let header_left = row![
        title_text,
        badge_framework,
        badge_backend,
        badge_simd,
        badge_arcswap,
    ]
    .spacing(8)
    .align_y(Alignment::Center);

    let node_badge = text(format!("Node: {}", hud.machine_id))
        .size(12)
        .color(Color::from_rgb8(150, 155, 165));

    let stream_status = text(format!("Active: {} / {}", hud.active_streams, hud.total_streams))
        .size(13)
        .color(Color::from_rgb8(200, 205, 215));

    let window_timer = text(format!(
        "Window: {:02}s / {:02}s (Flush #{})",
        hud.tick_in_window, hud.window_duration, hud.total_flushes
    ))
    .size(13)
    .color(Color::from_rgb8(180, 185, 195));

    let header_right = row![node_badge, stream_status, window_timer]
        .spacing(16)
        .align_y(Alignment::Center);

    let top_row = row![
        header_left,
        container(header_right).align_x(Alignment::End).width(Length::Fill),
    ]
    .align_y(Alignment::Center)
    .width(Length::Fill);

    // Row 2: Performance buckets and throughput
    let b_25_30 = text(format!(
        "25-30 FPS: {}",
        hud.current_buckets.acceptable.fps_25_to_30
    ))
    .size(12)
    .color(Color::from_rgb8(70, 220, 100));

    let b_20_24 = text(format!(
        "20-24 FPS: {}",
        hud.current_buckets.acceptable.fps_20_to_24
    ))
    .size(12)
    .color(Color::from_rgb8(240, 200, 50));

    let b_10_19 = text(format!(
        "10-19: {}",
        hud.current_buckets.unacceptable.fps_10_to_19
    ))
    .size(12)
    .color(if hud.current_buckets.unacceptable.fps_10_to_19 > 0 {
        Color::from_rgb8(240, 80, 80)
    } else {
        Color::from_rgb8(120, 125, 135)
    });

    let b_5_9 = text(format!(
        "5-9: {}",
        hud.current_buckets.unacceptable.fps_5_to_9
    ))
    .size(12)
    .color(if hud.current_buckets.unacceptable.fps_5_to_9 > 0 {
        Color::from_rgb8(240, 80, 80)
    } else {
        Color::from_rgb8(120, 125, 135)
    });

    let b_under_5 = text(format!(
        "<5: {}",
        hud.current_buckets.unacceptable.under_5_fps
    ))
    .size(12)
    .color(if hud.current_buckets.unacceptable.under_5_fps > 0 {
        Color::from_rgb8(240, 80, 80)
    } else {
        Color::from_rgb8(120, 125, 135)
    });

    let buckets_row = row![
        text("Buckets:").size(12).color(Color::from_rgb8(160, 165, 175)),
        b_25_30,
        b_20_24,
        b_10_19,
        b_5_9,
        b_under_5,
    ]
    .spacing(10)
    .align_y(Alignment::Center);

    let total_fps_text = text(format!(
        "Total: {} FPS (Avg: {:.1} FPS/cam)",
        hud.total_fps, hud.avg_fps
    ))
    .size(12)
    .color(Color::from_rgb8(220, 225, 235));

    let log_path_text = text(format!("Log: {}", hud.log_path))
        .size(11)
        .color(Color::from_rgb8(130, 135, 145));

    let stats_right = row![total_fps_text, log_path_text]
        .spacing(16)
        .align_y(Alignment::Center);

    let bottom_row = row![
        buckets_row,
        container(stats_right).align_x(Alignment::End).width(Length::Fill),
    ]
    .align_y(Alignment::Center)
    .width(Length::Fill);

    let hud_box = column![top_row, bottom_row]
        .spacing(4)
        .padding(6)
        .width(Length::Fill);

    container(hud_box)
        .width(Length::Fill)
        .style(|_| container::Style {
            background: Some(Background::Color(Color::from_rgb8(16, 18, 24))),
            border: Border {
                color: Color::from_rgb8(38, 42, 54),
                width: 1.0,
                radius: 0.0.into(),
            },
            ..Default::default()
        })
        .into()
}

fn make_badge<'a>(label: &'static str, bg_color: Color) -> Element<'a, Message> {
    container(
        text(label)
            .size(10)
            .color(Color::WHITE)
    )
    .padding([2, 6])
    .style(move |_| container::Style {
        background: Some(Background::Color(bg_color)),
        border: Border {
            color: Color::TRANSPARENT,
            width: 0.0,
            radius: 3.0.into(),
        },
        ..Default::default()
    })
    .into()
}

pub fn view_camera_tile<'a>(slot: &'a StreamSlot, stream_fps: u32) -> Element<'a, Message> {
    let stream_id = slot.stream_id;
    let (res_w, res_h) = {
        let res = slot.resolution.read().unwrap();
        *res
    };

    let content: Element<'a, Message> = if let Some(frame) = slot.get_current_frame() {
        slot.mark_painted();
        image(frame.handle.clone())
            .width(Length::Fill)
            .height(Length::Fill)
            .into()
    } else {
        let is_connected = slot.is_connected.load(Ordering::Relaxed);
        let status_str = if is_connected { "Decoding..." } else { "Connecting..." };

        container(
            column![
                text(format!("CAM {:02}", stream_id + 1))
                    .size(16)
                    .color(Color::from_rgb8(210, 215, 225)),
                text(status_str)
                    .size(11)
                    .color(Color::from_rgb8(130, 135, 145)),
            ]
            .align_x(Alignment::Center)
            .spacing(4)
        )
        .width(Length::Fill)
        .height(Length::Fill)
        .align_x(Alignment::Center)
        .align_y(Alignment::Center)
        .style(|_| container::Style {
            background: Some(Background::Color(Color::from_rgb8(22, 24, 30))),
            ..Default::default()
        })
        .into()
    };

    // Overlay Header on each camera tile
    let fps_color = if stream_fps >= 25 {
        Color::from_rgb8(60, 220, 90)
    } else if stream_fps >= 20 {
        Color::from_rgb8(250, 210, 40)
    } else {
        Color::from_rgb8(240, 70, 70)
    };

    let tile_overlay = row![
        text(format!("CAM {:02}", stream_id + 1))
            .size(11)
            .color(Color::WHITE),
        container(
            text(format!("{}x{}", res_w, res_h))
                .size(10)
                .color(Color::from_rgb8(180, 185, 195))
        )
        .align_x(Alignment::Center)
        .width(Length::Fill),
        text(format!("{} FPS", stream_fps))
            .size(11)
            .color(fps_color),
    ]
    .align_y(Alignment::Center)
    .padding([2, 6])
    .width(Length::Fill);

    let overlay_container = container(tile_overlay)
        .width(Length::Fill)
        .style(|_| container::Style {
            background: Some(Background::Color(Color::from_rgba(0.0, 0.0, 0.0, 0.60))),
            ..Default::default()
        });

    let tile_stack = stack![
        content,
        overlay_container,
    ];

    container(tile_stack)
        .width(Length::Fill)
        .height(Length::Fill)
        .style(|_| container::Style {
            background: Some(Background::Color(Color::BLACK)),
            border: Border {
                color: Color::from_rgb8(40, 44, 54),
                width: 1.0,
                radius: 2.0.into(),
            },
            ..Default::default()
        })
        .into()
}

pub fn view_grid<'a>(slots: &'a [std::sync::Arc<StreamSlot>], stream_fps: &'a [u32]) -> Element<'a, Message> {
    let count = slots.len();
    let cols = match count {
        1 => 1,
        2..=4 => 2,
        5..=6 => 3,
        7..=12 => 4,
        13..=20 => 5,
        _ => 6, // 30 streams = 6 columns x 5 rows
    };

    let mut grid_col = column![].spacing(2).width(Length::Fill).height(Length::Fill);

    for chunk in slots.chunks(cols) {
        let mut grid_row = row![].spacing(2).width(Length::Fill).height(Length::Fill);
        for slot in chunk {
            let fps = stream_fps.get(slot.stream_id).copied().unwrap_or(0);
            grid_row = grid_row.push(view_camera_tile(slot, fps));
        }
        grid_col = grid_col.push(grid_row);
    }

    container(grid_col)
        .padding(2)
        .width(Length::Fill)
        .height(Length::Fill)
        .style(|_| container::Style {
            background: Some(Background::Color(Color::from_rgb8(10, 11, 15))),
            ..Default::default()
        })
        .into()
}
