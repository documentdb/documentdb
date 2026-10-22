// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

//! Captures structured events from a single tracing target.

use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};

use tracing::{
    field::{Field, Visit},
    Event, Level, Subscriber,
};
use tracing_subscriber::{layer::Context, Layer};

#[derive(Clone, Debug)]
pub struct CapturedEvent {
    pub level: Level,
    pub fields: HashMap<String, String>,
}

#[derive(Clone, Debug)]
pub struct LogCapture {
    target: &'static str,
    events: Arc<Mutex<Vec<CapturedEvent>>>,
}

impl LogCapture {
    pub fn new(target: &'static str) -> Self {
        Self {
            target,
            events: Arc::default(),
        }
    }

    pub fn events(&self) -> Vec<CapturedEvent> {
        self.events
            .lock()
            .expect("log capture lock should not be poisoned")
            .clone()
    }
}

impl<S: Subscriber> Layer<S> for LogCapture {
    fn on_event(&self, event: &Event<'_>, _ctx: Context<'_, S>) {
        if event.metadata().target() != self.target {
            return;
        }
        let mut fields = HashMap::new();
        event.record(&mut FieldCollector(&mut fields));
        self.events
            .lock()
            .expect("log capture lock should not be poisoned")
            .push(CapturedEvent {
                level: *event.metadata().level(),
                fields,
            });
    }
}

struct FieldCollector<'a>(&'a mut HashMap<String, String>);

impl Visit for FieldCollector<'_> {
    fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
        self.0.insert(field.name().to_owned(), format!("{value:?}"));
    }

    fn record_str(&mut self, field: &Field, value: &str) {
        self.0.insert(field.name().to_owned(), value.to_owned());
    }

    fn record_u64(&mut self, field: &Field, value: u64) {
        self.0.insert(field.name().to_owned(), value.to_string());
    }
}
