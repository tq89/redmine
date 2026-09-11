# Redmine Approval Workflow — Lưu trình ký & Gia hạn

Plugin bổ sung hai tính năng cho Redmine 7:

1. **Lưu trình ký** — chuỗi bước ký duyệt có thứ tự; mỗi lần ký sẽ tự đổi trạng thái công việc theo lưu trình đã thiết lập.
2. **Gia hạn công việc** — đẩy ngày hoàn thành sang mốc mới, với giới hạn số ngày tối đa cho mỗi lần do quản trị viên đặt.

## Nguyên tắc phân quyền ký duyệt

Plugin **không** tạo ra hệ thống quyền riêng cho việc ký. Quyền ký một bước
chính là quyền chuyển công việc sang trạng thái đích của bước đó, tức là
luồng công việc thiết lập tại **Quản trị → Luồng công việc**.

Về mặt kỹ thuật, mọi lần ký đều đi qua:

```ruby
issue.attributes_editable?(user) &&
  issue.new_statuses_allowed_to(user).include?(target_status)
```

Kiểm tra này được thực hiện **tường minh** trong `ApprovalsController#create`.
Lý do: `Issue#safe_attributes=` của Redmine (`app/models/issue.rb:619-623`)
âm thầm **bỏ qua** status không được phép thay vì báo lỗi — nếu dựa vào nó thì
một chữ ký trái phép sẽ trông như thành công trong khi trạng thái không đổi.

Hệ quả: muốn cấp quyền ký bước "Giám đốc duyệt" cho vai trò nào, chỉ cần cho
vai trò đó quyền chuyển sang trạng thái tương ứng trong luồng công việc.

## Quyền gia hạn cũng lấy từ luồng công việc

Ký duyệt bám vào *chuyển trạng thái*; gia hạn ghi vào trường `due_date` nên nó
bám vào **quyền trên trường** — tab *Quyền trên trường* trong
**Quản trị → Luồng công việc**. Đặt `due_date` là **Chỉ đọc** cho một vai trò ở
một trạng thái nào đó thì vai trò đó không gia hạn được ở trạng thái ấy.

Điều kiện đầy đủ để gia hạn:

```ruby
issue.attributes_editable?(user) &&
  user.allowed_to?(:extend_issue_due_date, project) &&
  !issue.read_only_attribute_names(user).include?('due_date') &&
  (số lần gia hạn chưa vượt giới hạn)
```

Kiểm tra `read_only_attribute_names` phải làm tường minh vì plugin gán
`due_date` trực tiếp chứ không qua `safe_attributes=` — cùng lý do như với
status.

## Nút nhắc ký trên thanh menu

Khi có bước đang chờ chữ ký của bạn, thanh menu trên cùng hiện mục
**Chờ ký (n)** dẫn tới danh sách công việc. Mục này tự ẩn khi không còn gì để ký.

Caption của menu bị `h()` escape (`lib/redmine/menu_manager.rb:187`) nên số đếm
là text thường, không phải badge HTML.

**Về hiệu năng** — mục này render trên *mọi* trang, nên phép tra cứu được viết
theo lô: routes, chữ ký và workflow transitions mỗi thứ lấy **một** lần rồi
đối chiếu trong bộ nhớ. Số query **không tăng theo số lượng issue**
(đo được: 26 query với 3 issue, vẫn 26 query với 43 issue). Nếu gọi thẳng
`Issue#can_approve?` cho từng issue thì tốn ~10 query/issue.

`Issue#can_approve?` vẫn là chuẩn mực — controller dùng nó — và
`PendingApprovalsTest` ghim đường nhanh vào nó bằng các test so sánh kết quả
hai bên. **Sửa một bên thì phải sửa bên kia.**

Quản trị viên có thể tắt nút này (Quản trị → Plugins → Cấu hình) nếu máy chủ yếu.

## Gửi email khi tới lượt ký (tuỳ chọn)

Bật tại **Quản trị → Plugins → Cấu hình → Gửi email khi tới lượt ký**.
**Mặc định tắt** — hãy kiểm tra cấu hình email của bạn trước khi bật.

Mail được gửi khi:

- tạo công việc mới thuộc tracker có lưu trình (bước 1 lập tức chờ ký);
- ai đó **ký duyệt** xong, bước kế tiếp chuyển sang người khác;
- ai đó **từ chối**, công việc trả về bước trước đó.

Người nhận là những ai có quyền ký bước đang chờ — tức là có quyền chuyển sang
trạng thái đích của bước đó. Danh sách được thu hẹp trước bằng các vai trò thật
sự nắm chuyển trạng thái, nên dự án đông người không đồng nghĩa với việc kiểm
tra từng thành viên.

Không gửi cho: người vừa thao tác (không ai nhận mail về hành động của chính
mình), người đã tắt hẳn thông báo (`mail_notification = none`), người không
nhìn thấy công việc.

> **Lưu ý:** ký duyệt cũng là một lần cập nhật công việc, nên Redmine vẫn gửi
> thông báo "issue updated" như thường lệ. Bật tuỳ chọn này nghĩa là người ký
> tiếp theo có thể nhận **hai** email. Tuỳ chọn này chỉ điều khiển mail của
> plugin, không đụng tới thông báo gốc của Redmine.

`ApprovalMailer` kế thừa `Mailer` của Redmine nên dùng chung From, List-Id,
delivery job và tuỳ chọn *"Không gửi thông báo về thay đổi do tôi tạo ra"*.
Lỗi gửi mail lúc tạo công việc được bắt lại và ghi log — không bao giờ làm
hỏng việc tạo công việc.

> Redmine mặc định dùng ActiveJob adapter `:async` (chạy thread trong chính
> tiến trình Puma). Nếu máy chủ đang căng, cân nhắc kỹ trước khi bật thêm
> nguồn gửi mail.

## Cài đặt

```bash
# copy plugin vào thư mục plugins/ rồi:
bundle exec rake redmine:plugins:migrate RAILS_ENV=production
# restart Redmine
```

Bật module **Lưu trình ký & Gia hạn** trong Cài đặt dự án → Mô-đun.

## Thiết lập

**Quản trị → Lưu trình ký**: tạo lưu trình gồm tên, tracker, dự án (để trống =
áp dụng mọi dự án), trạng thái khi bị từ chối, và danh sách bước theo thứ tự.

Lưu trình gắn với một dự án được ưu tiên hơn lưu trình chung của cùng tracker.

**Quản trị → Plugins → Cấu hình**:

| Thiết lập | Mặc định | Ý nghĩa |
|---|---|---|
| Số ngày tối đa mỗi lần gia hạn | 30 | 0 = không giới hạn |
| Số lần gia hạn tối đa | 0 | 0 = không giới hạn |
| Bắt buộc nhập lý do gia hạn | có | |
| Hiện nút nhắc ký trên thanh menu | có | tắt để giảm tải máy chủ |
| Gửi email khi tới lượt ký | **không** | xem mục riêng bên dưới |

## Cách hoạt động

Tiến độ lưu trình được suy ra từ bảng `approval_signatures`, **không** từ
trạng thái công việc. Nhờ vậy một lần đổi trạng thái thủ công bên ngoài lưu
trình không thể lặng lẽ bỏ qua một bước — khi lệch, panel hiện cảnh báo.

- **Ký duyệt** bước `p`: trạng thái → status của bước `p`, con trỏ tiến lên `p+1`.
- **Từ chối** bước `p`: con trỏ lùi về `max(0, p-1)`; trạng thái về status của
  bước `p-2`, hoặc "trạng thái khi bị từ chối" nếu đang ở đầu lưu trình.

Mỗi thao tác đều tạo một journal trên công việc, nên lịch sử hiển thị đầy đủ
trong tab thông thường của Redmine.

## Quyền

| Quyền | Tác dụng |
|---|---|
| Xem lưu trình ký | Hiện panel lưu trình trên trang công việc |
| Gia hạn công việc | Cho phép bấm nút Gia hạn (còn phải qua quyền trên trường `due_date`) |

Quản lý lưu trình chỉ dành cho quản trị viên hệ thống.

## Kiểm thử

```bash
bundle exec rails test plugins/redmine_approval_workflow/test RAILS_ENV=test
```

84 test, 284 assertion.
