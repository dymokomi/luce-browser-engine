# Region p4a: animations — what other regions need to know

Region p4a ports CSS animations and transitions ahead of phase 4, because real sites trap in them (theverge.com
trapped on `unported (P4): Web::CSS::EasingFunction::from_style_value` while computing an element's `animation`). It
ports `CSS/EasingFunction`, `Animations/` (`Animation`, `AnimationEffect`, `KeyframeEffect`, `TimeValue`,
`AnimationPlaybackEvent`, `ScrollTimeline`, `PseudoElementParsing` and the rest of `Animatable`,
`AnimationTimeline` and `DocumentTimeline`), `CSS/CSSAnimation`, `CSS/CSSTransition`, `CSS/AnimationEvent`,
`CSS/TransitionEvent`, all of `CSS/Interpolation.cpp`, and Document's animation update: the default timeline, the
pending animation events and their dispatch, removing replaced animations and getAnimations(). An element's
`animation` makes a CSSAnimation on the document timeline, a change of a transitioned property starts a
CSSTransition, every update of the rendering advances the timelines, runs the pending play and pause tasks, fires
`animationstart`/`iteration`/`end`/`cancel` and `transitionrun`/`start`/`end`/`cancel` at the element, and the
interpolated values reach the element's computed properties (StyleComputer's `collect_animation_into`, region r39).

## Fragments

| Fragment | Donor |
| --- | --- |
| `css/easing_function` (+ `types_easing_function`, ControlPoint filled) | `EasingFunction.cpp` 1-375 |
| `animations/time_value` (+ `types_time_value`, new: moved from the closure stubs) | `TimeValue.cpp` 1-79 with `TimeValue.h`'s operators and NullableCSSNumberish |
| `animations/animation_1` … `_4` (+ `types_animation`, filled) | `Animation.cpp` 1-1621 with `Animation.h`'s inline members |
| `animations/animation_effect_1`, `_2` (+ `types_animation_effect`, new) | `AnimationEffect.cpp` 1-460, 462-865 with `AnimationEffect.h`'s inline members; AnimationUpdateContext |
| `animations/keyframe_effect` (+ `types_keyframe_effect`, filled) | `KeyframeEffect.cpp` 1-574, 627-989 (r39 has generate_initial_and_final_frames) |
| `animations/animation_playback_event` (+ types, new) | `AnimationPlaybackEvent.cpp` 1-79 |
| `animations/scroll_timeline` (+ types, new) | `ScrollTimeline.cpp` 1-227 |
| `animations/pseudo_element_parsing` | `PseudoElementParsing.cpp` 1-38 |
| `animations/animatable`, `animation_timeline`, `document_timeline` (extended) | `Animatable.cpp` (animate, getAnimations, associate/disassociate, transitions), `AnimationTimeline.cpp`'s associations and time conversions |
| `css/css_animation`, `css/css_transition` (+ types, filled) | `CSSAnimation.cpp` 1-153, `CSSTransition.cpp` 1-177 |
| `css/animation_event`, `css/transition_event` (+ types, new) | `AnimationEvent.cpp`, `TransitionEvent.cpp` |
| `css/interpolation_1` … `_6` (+ `types_interpolation`, new) | `Interpolation.cpp` 1-2677 (each fragment's header has its lines) |
| `external/lib_gfx/vector_n` | `LibGfx/VectorN.h`'s FloatVector3/4 arithmetic (below) |
| `dom/document_animations` (new, split out of `document_6` and `document_11`) | `Document.cpp` 3101-3357 (the transition and animation events), 5994-6198 (timelines, update_animations_and_send_events, remove_replaced_animations, getAnimations) |
| `generated/bindings/types_animation`, `types_animation_effect`, `types_scroll_timeline` | the IDL enums `AnimationPlayState`, `AnimationReplaceState`, `FillMode`, `PlaybackDirection`, `ScrollAxis` |
| `css/tests_easing_function` (+ `_expected`), `animations/tests_animations` | tests (below) |

## What other regions must know

### Classes

- `Animation`, `CSSAnimation` and `CSSTransition` share EventTarget's class id (49); `KeyframeEffect` and
  `ScrollTimeline` PlatformObject's (6; the abstract `AnimationEffect` has no ClassInfo of its own);
  `AnimationPlaybackEvent`, `AnimationEvent` and `TransitionEvent` DOM::Event's (47). They are
  recognized by their ClassInfo (`is_animations_animation` accepts the two CSS subclasses), as the phase-2 classes
  are (DESIGN §8.2).
- `Animation`'s virtuals (`is_css_animation`, `is_css_transition`, `animation_class`,
  `class_specific_composite_order`, `set_timeline_for_bindings`, …) are `AnimationsAnimationVTable` slots;
  `AnimationEffect`'s (`target`, `is_keyframe_effect`, `update_computed_properties`) are `AnimationsAnimationEffectVTable`
  slots; `AnimationTimeline` gained `convert_a_timeline_time_to_an_origin_relative_time` and
  `can_convert_a_timeline_time_to_an_origin_relative_time`.

### Signatures and types changed

- Types moved out of `stubs/stub_closure.lucb` into their files: `AnimationsTimeValue` (+ `Type`),
  `AnimationsAnimationEffect`, `AnimationsAnimationUpdateContext`, `AnimationsAnimationShouldInvalidate`,
  `AnimationsAnimatableTransitionAttributes`, `AnimationsAnimatableGetAnimationsSorted`,
  `AnimationsGetAnimationsOptions`, `AnimationsScrollTimelineAnonymousSource`, `CssAllowDiscrete`,
  `BindAnimationReplaceState`, `BindScrollAxis`.
- `animations_scroll_timeline_create(realm, document, source: AnimationsScrollTimelineSource, axis)` takes C++'s
  `Source` variant (an element or an anonymous source); computed_properties_5 wraps its anonymous source.
- `dom_document_dispatch_events_for_transition` and `dom_document_dispatch_events_for_animation_if_necessary` are
  private to `document_animations`, as in C++.
- Casts of the formerly opaque types are typed upcasts now (`.animations_animation_timeline()`,
  `.animations_animation()`, `as_animations_keyframe_effect`) in computed_properties_5, style_computer_3/4/6,
  element_12, document_1 and document_or_shadow_root.
- `calculate_get_animations` (DocumentOrShadowRoot) runs: its callbacks were traps.
- TransformationStyleValue's private `css_float_vector3_length`/`normalized` (r51a) are gone; its callers use
  `gfx_float_vector3_length`/`normalized` of `external/lib_gfx/vector_n`. luce-browser-render's gfx declares
  FloatVector3/4 without methods (r08 left them to CSS transform interpolation); the package is pinned, so the methods
  are web's (DESIGN §4.4).

### Closure stubs removed (ported)

46 closure stubs: every `unported (P4)` of Web::Animations, EasingFunction (`from_style_value`, `evaluate_at`),
CSSAnimation (`create`, `set_animation_name`, `apply_css_properties`, `default_easing`), CSSTransition
(`start_a_transition`, the reversing values, `timing_function_output_at_time`), Interpolation (`interpolate_property`,
`property_values_are_transitionable`, `composite_value`), ScrollTimeline and PseudoElementParsing.

### Still trapping

The JS-facing entry points keep their signatures and trap `unported (P3)`: `new Animation()`
(`Animation::construct_impl`), `new KeyframeEffect()`, `KeyframeEffect::getKeyframes()`, a non-null keyframes
argument of `setKeyframes()`/`animate()` (`process_a_keyframes_argument` reads JS objects), and CSSNumberish times that
are CSSNumericValues (`TimeValue::from_css_numberish`, Animation's time validation). `Interpolation.cpp`'s
`length_percentage_or_auto_to_style_value` is a template no code instantiates and is not ported.

### Donor behaviour kept

- `CSSTransition::timing_function_output_at_time`'s AD-HOC empty-duration check is inverted in Ladybird (it tests
  `start < end`); the port keeps it (`# donor bug`), as faithful ports do.
- Interpolation's function-local statics (the identity scale, translate and rotate values) are made once in the C heap
  with ak's atomic allocator unset (DESIGN §3.3 rule 7).

## The web_test harness

`worker_load_and_wait` drains the main event loop's rendering tasks before loading a reference. test-web navigates
the view to the reference, so an update of the rendering queued for the test's document (a running CSS animation
requests a frame on every one) runs while that document is active; the harness replaces the active document
synchronously, which left that task queued and not runnable, and EventLoop's "a rendering task is already queued"
check then never queued another one: the reference never painted and the worker stalled. Ref tests with animations
reach the comparison now.

## Tests

- `css/tests_easing_function`: the 30 easing functions of the oracle (keywords, cubic-bezier(), steps() with each
  jump term, linear() with its canonicalization) are parsed as AnimationEffect's `parse_easing_string` does,
  serialized, and evaluated at 16 inputs with and without the before flag; the dump is compared with the reference
  build's (`luce-browser-tools/oracles/luce-browser-engine/animations/oracle.cpp`, local), doubles within 64 ulps.
  Ladybird has no EasingFunction unit tests.
- `animations/tests_animations`: documents built as tests_layout_tree builds them, driven frame by frame through
  `update_animations_and_send_events` and `update_animated_style_if_needed`: a CSS animation starts at the first
  frame, interpolates `width` linearly, finishes with `animationstart`/`animationend` and their elapsed times; a paused
  animation with a negative delay holds its value; an alternating animation fires `animationiteration` and runs
  backwards; a transition fires `transitionrun`/`transitionstart`/`transitionend` and interpolates.
- web_test: four Ref and four Crash tests with animations pass now and left `tests/expected_failures`.
