use crate::decoder::{GpuFrameData, StreamSlot};
use bytemuck::{Pod, Zeroable};
use iced::mouse;
use iced::widget::shader::{self, Program};
use iced::Rectangle;
use iced_wgpu::graphics::Viewport;
use iced_wgpu::primitive::{Pipeline, Primitive};
use iced_wgpu::wgpu::{self, util::DeviceExt};
use std::collections::HashMap;
use std::sync::Arc;

#[repr(C)]
#[derive(Copy, Clone, Debug, Pod, Zeroable)]
pub struct Vertex {
    pub position: [f32; 2],
    pub tex_coords: [f32; 2],
}

const VERTICES: [Vertex; 6] = [
    Vertex { position: [-1.0, -1.0], tex_coords: [0.0, 1.0] },
    Vertex { position: [1.0, -1.0],  tex_coords: [1.0, 1.0] },
    Vertex { position: [1.0, 1.0],   tex_coords: [1.0, 0.0] },
    Vertex { position: [-1.0, -1.0], tex_coords: [0.0, 1.0] },
    Vertex { position: [1.0, 1.0],   tex_coords: [1.0, 0.0] },
    Vertex { position: [-1.0, 1.0],  tex_coords: [0.0, 0.0] },
];

const RGBA_SHADER_SOURCE: &str = r#"
struct VertexInput {
    @location(0) position: vec2<f32>,
    @location(1) tex_coords: vec2<f32>,
};

struct VertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) tex_coords: vec2<f32>,
};

@vertex
fn vs_main(model: VertexInput) -> VertexOutput {
    var out: VertexOutput;
    out.clip_position = vec4<f32>(model.position, 0.0, 1.0);
    out.tex_coords = model.tex_coords;
    return out;
}

@group(0) @binding(0)
var t_diffuse: texture_2d<f32>;
@group(0) @binding(1)
var s_diffuse: sampler;

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    return textureSample(t_diffuse, s_diffuse, in.tex_coords);
}
"#;

const NV12_SHADER_SOURCE: &str = r#"
struct VertexInput {
    @location(0) position: vec2<f32>,
    @location(1) tex_coords: vec2<f32>,
};

struct VertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) tex_coords: vec2<f32>,
};

@vertex
fn vs_main(model: VertexInput) -> VertexOutput {
    var out: VertexOutput;
    out.clip_position = vec4<f32>(model.position, 0.0, 1.0);
    out.tex_coords = model.tex_coords;
    return out;
}

@group(0) @binding(0)
var t_y: texture_2d<f32>;
@group(0) @binding(1)
var t_uv: texture_2d<f32>;
@group(0) @binding(2)
var s_video: sampler;

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let y = textureSample(t_y, s_video, in.tex_coords).r;
    let uv = textureSample(t_uv, s_video, in.tex_coords).rg;

    // Standard BT.709 YUV -> RGB conversion
    let u = uv.r - 0.5;
    let v = uv.g - 0.5;

    let r = y + 1.5748 * v;
    let g = y - 0.1873 * u - 0.4681 * v;
    let b = y + 1.8556 * u;

    return vec4<f32>(clamp(r, 0.0, 1.0), clamp(g, 0.0, 1.0), clamp(b, 0.0, 1.0), 1.0);
}
"#;

enum CachedTile {
    Rgba {
        texture: wgpu::Texture,
        bind_group: wgpu::BindGroup,
        width: u32,
        height: u32,
        last_timestamp_us: u64,
    },
    Nv12 {
        texture_y: wgpu::Texture,
        texture_uv: wgpu::Texture,
        bind_group: wgpu::BindGroup,
        width: u32,
        height: u32,
        last_timestamp_us: u64,
    },
}

pub struct VideoPipeline {
    render_pipeline_rgba: wgpu::RenderPipeline,
    render_pipeline_nv12: wgpu::RenderPipeline,
    bind_group_layout_rgba: wgpu::BindGroupLayout,
    bind_group_layout_nv12: wgpu::BindGroupLayout,
    sampler: wgpu::Sampler,
    vertex_buffer: wgpu::Buffer,
    textures: HashMap<usize, CachedTile>,
}

impl Pipeline for VideoPipeline {
    fn new(
        device: &wgpu::Device,
        _queue: &wgpu::Queue,
        format: wgpu::TextureFormat,
    ) -> Self {
        let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("video_sampler"),
            address_mode_u: wgpu::AddressMode::ClampToEdge,
            address_mode_v: wgpu::AddressMode::ClampToEdge,
            address_mode_w: wgpu::AddressMode::ClampToEdge,
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            mipmap_filter: wgpu::FilterMode::Nearest,
            ..Default::default()
        });

        let vertex_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("video_quad_vertex_buffer"),
            contents: bytemuck::cast_slice(&VERTICES),
            usage: wgpu::BufferUsages::VERTEX,
        });

        // 1. RGBA Pipeline
        let shader_rgba = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("video_tile_rgba_shader"),
            source: wgpu::ShaderSource::Wgsl(RGBA_SHADER_SOURCE.into()),
        });

        let bind_group_layout_rgba = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("video_bind_group_layout_rgba"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture {
                        sample_type: wgpu::TextureSampleType::Float { filterable: true },
                        view_dimension: wgpu::TextureViewDimension::D2,
                        multisampled: false,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                    count: None,
                },
            ],
        });

        let pipeline_layout_rgba = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("video_pipeline_layout_rgba"),
            bind_group_layouts: &[&bind_group_layout_rgba],
            push_constant_ranges: &[],
        });

        let render_pipeline_rgba = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("video_render_pipeline_rgba"),
            layout: Some(&pipeline_layout_rgba),
            vertex: wgpu::VertexState {
                module: &shader_rgba,
                entry_point: Some("vs_main"),
                compilation_options: Default::default(),
                buffers: &[wgpu::VertexBufferLayout {
                    array_stride: std::mem::size_of::<Vertex>() as wgpu::BufferAddress,
                    step_mode: wgpu::VertexStepMode::Vertex,
                    attributes: &[
                        wgpu::VertexAttribute {
                            offset: 0,
                            shader_location: 0,
                            format: wgpu::VertexFormat::Float32x2,
                        },
                        wgpu::VertexAttribute {
                            offset: std::mem::size_of::<[f32; 2]>() as wgpu::BufferAddress,
                            shader_location: 1,
                            format: wgpu::VertexFormat::Float32x2,
                        },
                    ],
                }],
            },
            fragment: Some(wgpu::FragmentState {
                module: &shader_rgba,
                entry_point: Some("fs_main"),
                compilation_options: Default::default(),
                targets: &[Some(wgpu::ColorTargetState {
                    format,
                    blend: Some(wgpu::BlendState::REPLACE),
                    write_mask: wgpu::ColorWrites::ALL,
                })],
            }),
            primitive: wgpu::PrimitiveState {
                topology: wgpu::PrimitiveTopology::TriangleList,
                strip_index_format: None,
                front_face: wgpu::FrontFace::Ccw,
                cull_mode: None,
                polygon_mode: wgpu::PolygonMode::Fill,
                unclipped_depth: false,
                conservative: false,
            },
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview: None,
            cache: None,
        });

        // 2. NV12 Hardware Color Conversion Pipeline
        let shader_nv12 = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("video_tile_nv12_shader"),
            source: wgpu::ShaderSource::Wgsl(NV12_SHADER_SOURCE.into()),
        });

        let bind_group_layout_nv12 = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("video_bind_group_layout_nv12"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture {
                        sample_type: wgpu::TextureSampleType::Float { filterable: true },
                        view_dimension: wgpu::TextureViewDimension::D2,
                        multisampled: false,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture {
                        sample_type: wgpu::TextureSampleType::Float { filterable: true },
                        view_dimension: wgpu::TextureViewDimension::D2,
                        multisampled: false,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 2,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                    count: None,
                },
            ],
        });

        let pipeline_layout_nv12 = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("video_pipeline_layout_nv12"),
            bind_group_layouts: &[&bind_group_layout_nv12],
            push_constant_ranges: &[],
        });

        let render_pipeline_nv12 = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("video_render_pipeline_nv12"),
            layout: Some(&pipeline_layout_nv12),
            vertex: wgpu::VertexState {
                module: &shader_nv12,
                entry_point: Some("vs_main"),
                compilation_options: Default::default(),
                buffers: &[wgpu::VertexBufferLayout {
                    array_stride: std::mem::size_of::<Vertex>() as wgpu::BufferAddress,
                    step_mode: wgpu::VertexStepMode::Vertex,
                    attributes: &[
                        wgpu::VertexAttribute {
                            offset: 0,
                            shader_location: 0,
                            format: wgpu::VertexFormat::Float32x2,
                        },
                        wgpu::VertexAttribute {
                            offset: std::mem::size_of::<[f32; 2]>() as wgpu::BufferAddress,
                            shader_location: 1,
                            format: wgpu::VertexFormat::Float32x2,
                        },
                    ],
                }],
            },
            fragment: Some(wgpu::FragmentState {
                module: &shader_nv12,
                entry_point: Some("fs_main"),
                compilation_options: Default::default(),
                targets: &[Some(wgpu::ColorTargetState {
                    format,
                    blend: Some(wgpu::BlendState::REPLACE),
                    write_mask: wgpu::ColorWrites::ALL,
                })],
            }),
            primitive: wgpu::PrimitiveState {
                topology: wgpu::PrimitiveTopology::TriangleList,
                strip_index_format: None,
                front_face: wgpu::FrontFace::Ccw,
                cull_mode: None,
                polygon_mode: wgpu::PolygonMode::Fill,
                unclipped_depth: false,
                conservative: false,
            },
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview: None,
            cache: None,
        });

        Self {
            render_pipeline_rgba,
            render_pipeline_nv12,
            bind_group_layout_rgba,
            bind_group_layout_nv12,
            sampler,
            vertex_buffer,
            textures: HashMap::new(),
        }
    }
}

#[derive(Debug)]
pub struct VideoTilePrimitive {
    pub stream_id: usize,
    pub frame: Option<Arc<GpuFrameData>>,
}

impl Primitive for VideoTilePrimitive {
    type Pipeline = VideoPipeline;

    fn prepare(
        &self,
        pipeline: &mut Self::Pipeline,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        _bounds: &Rectangle,
        _viewport: &Viewport,
    ) {
        let frame = match &self.frame {
            Some(f) => f,
            None => return,
        };

        let stream_id = self.stream_id;
        let width = frame.width.max(1);
        let height = frame.height.max(1);

        if let Some((ref y_plane, ref uv_plane)) = frame.nv12_planes {
            let needs_recreate = match pipeline.textures.get(&stream_id) {
                Some(CachedTile::Nv12 { width: w, height: h, .. }) => *w != width || *h != height,
                _ => true,
            };

            if needs_recreate {
                let texture_y = device.create_texture(&wgpu::TextureDescriptor {
                    label: Some(&format!("stream_{}_y", stream_id)),
                    size: wgpu::Extent3d {
                        width,
                        height,
                        depth_or_array_layers: 1,
                    },
                    mip_level_count: 1,
                    sample_count: 1,
                    dimension: wgpu::TextureDimension::D2,
                    format: wgpu::TextureFormat::R8Unorm,
                    usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
                    view_formats: &[],
                });

                let uv_width = (width / 2).max(1);
                let uv_height = (height / 2).max(1);

                let texture_uv = device.create_texture(&wgpu::TextureDescriptor {
                    label: Some(&format!("stream_{}_uv", stream_id)),
                    size: wgpu::Extent3d {
                        width: uv_width,
                        height: uv_height,
                        depth_or_array_layers: 1,
                    },
                    mip_level_count: 1,
                    sample_count: 1,
                    dimension: wgpu::TextureDimension::D2,
                    format: wgpu::TextureFormat::Rg8Unorm,
                    usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
                    view_formats: &[],
                });

                let view_y = texture_y.create_view(&wgpu::TextureViewDescriptor::default());
                let view_uv = texture_uv.create_view(&wgpu::TextureViewDescriptor::default());

                let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
                    label: Some(&format!("stream_{}_nv12_bind_group", stream_id)),
                    layout: &pipeline.bind_group_layout_nv12,
                    entries: &[
                        wgpu::BindGroupEntry {
                            binding: 0,
                            resource: wgpu::BindingResource::TextureView(&view_y),
                        },
                        wgpu::BindGroupEntry {
                            binding: 1,
                            resource: wgpu::BindingResource::TextureView(&view_uv),
                        },
                        wgpu::BindGroupEntry {
                            binding: 2,
                            resource: wgpu::BindingResource::Sampler(&pipeline.sampler),
                        },
                    ],
                });

                pipeline.textures.insert(
                    stream_id,
                    CachedTile::Nv12 {
                        texture_y,
                        texture_uv,
                        bind_group,
                        width,
                        height,
                        last_timestamp_us: 0,
                    },
                );
            }

            if let Some(CachedTile::Nv12 { texture_y, texture_uv, last_timestamp_us, .. }) = pipeline.textures.get_mut(&stream_id) {
                if frame.timestamp_us != *last_timestamp_us {
                    *last_timestamp_us = frame.timestamp_us;

                    queue.write_texture(
                        wgpu::TexelCopyTextureInfo {
                            texture: texture_y,
                            mip_level: 0,
                            origin: wgpu::Origin3d::ZERO,
                            aspect: wgpu::TextureAspect::All,
                        },
                        y_plane,
                        wgpu::TexelCopyBufferLayout {
                            offset: 0,
                            bytes_per_row: Some(width),
                            rows_per_image: Some(height),
                        },
                        wgpu::Extent3d {
                            width,
                            height,
                            depth_or_array_layers: 1,
                        },
                    );

                    let uv_width = (width / 2).max(1);
                    let uv_height = (height / 2).max(1);

                    queue.write_texture(
                        wgpu::TexelCopyTextureInfo {
                            texture: texture_uv,
                            mip_level: 0,
                            origin: wgpu::Origin3d::ZERO,
                            aspect: wgpu::TextureAspect::All,
                        },
                        uv_plane,
                        wgpu::TexelCopyBufferLayout {
                            offset: 0,
                            bytes_per_row: Some(uv_width * 2),
                            rows_per_image: Some(uv_height),
                        },
                        wgpu::Extent3d {
                            width: uv_width,
                            height: uv_height,
                            depth_or_array_layers: 1,
                        },
                    );
                }
            }
        } else if let Some(ref pixels) = frame.rgba_pixels {
            let needs_recreate = match pipeline.textures.get(&stream_id) {
                Some(CachedTile::Rgba { width: w, height: h, .. }) => *w != width || *h != height,
                _ => true,
            };

            if needs_recreate {
                let texture = device.create_texture(&wgpu::TextureDescriptor {
                    label: Some(&format!("stream_{}_rgba", stream_id)),
                    size: wgpu::Extent3d {
                        width,
                        height,
                        depth_or_array_layers: 1,
                    },
                    mip_level_count: 1,
                    sample_count: 1,
                    dimension: wgpu::TextureDimension::D2,
                    format: wgpu::TextureFormat::Rgba8Unorm,
                    usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
                    view_formats: &[],
                });

                let view = texture.create_view(&wgpu::TextureViewDescriptor::default());

                let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
                    label: Some(&format!("stream_{}_rgba_bind_group", stream_id)),
                    layout: &pipeline.bind_group_layout_rgba,
                    entries: &[
                        wgpu::BindGroupEntry {
                            binding: 0,
                            resource: wgpu::BindingResource::TextureView(&view),
                        },
                        wgpu::BindGroupEntry {
                            binding: 1,
                            resource: wgpu::BindingResource::Sampler(&pipeline.sampler),
                        },
                    ],
                });

                pipeline.textures.insert(
                    stream_id,
                    CachedTile::Rgba {
                        texture,
                        bind_group,
                        width,
                        height,
                        last_timestamp_us: 0,
                    },
                );
            }

            if let Some(CachedTile::Rgba { texture, last_timestamp_us, .. }) = pipeline.textures.get_mut(&stream_id) {
                if frame.timestamp_us != *last_timestamp_us {
                    *last_timestamp_us = frame.timestamp_us;

                    queue.write_texture(
                        wgpu::TexelCopyTextureInfo {
                            texture,
                            mip_level: 0,
                            origin: wgpu::Origin3d::ZERO,
                            aspect: wgpu::TextureAspect::All,
                        },
                        pixels,
                        wgpu::TexelCopyBufferLayout {
                            offset: 0,
                            bytes_per_row: Some(width * 4),
                            rows_per_image: Some(height),
                        },
                        wgpu::Extent3d {
                            width,
                            height,
                            depth_or_array_layers: 1,
                        },
                    );
                }
            }
        }
    }

    fn draw(
        &self,
        pipeline: &Self::Pipeline,
        render_pass: &mut wgpu::RenderPass<'_>,
    ) -> bool {
        if let Some(entry) = pipeline.textures.get(&self.stream_id) {
            match entry {
                CachedTile::Nv12 { bind_group, .. } => {
                    render_pass.set_pipeline(&pipeline.render_pipeline_nv12);
                    render_pass.set_bind_group(0, bind_group, &[]);
                    render_pass.set_vertex_buffer(0, pipeline.vertex_buffer.slice(..));
                    render_pass.draw(0..6, 0..1);
                    true
                }
                CachedTile::Rgba { bind_group, .. } => {
                    render_pass.set_pipeline(&pipeline.render_pipeline_rgba);
                    render_pass.set_bind_group(0, bind_group, &[]);
                    render_pass.set_vertex_buffer(0, pipeline.vertex_buffer.slice(..));
                    render_pass.draw(0..6, 0..1);
                    true
                }
            }
        } else {
            false
        }
    }
}

pub struct VideoTileProgram {
    pub slot: Arc<StreamSlot>,
}

impl<Message> Program<Message> for VideoTileProgram {
    type State = ();
    type Primitive = VideoTilePrimitive;

    fn draw(
        &self,
        _state: &Self::State,
        _cursor: mouse::Cursor,
        _bounds: Rectangle,
    ) -> Self::Primitive {
        self.slot.mark_painted();
        VideoTilePrimitive {
            stream_id: self.slot.stream_id,
            frame: self.slot.get_current_frame(),
        }
    }
}

pub fn video_tile<Message>(slot: Arc<StreamSlot>) -> shader::Shader<Message, VideoTileProgram> {
    shader::Shader::new(VideoTileProgram { slot })
}
