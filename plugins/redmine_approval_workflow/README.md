# Redmine Approval Workflow — Lưu trình ký & Gia hạn

Plugin bổ sung hai tính năng cho Redmine 7:

1. **Lưu trình ký** — chuỗi bước ký duyệt có thứ tự; mỗi lần ký sẽ tự đổi trạng thái công việc theo lưu trình đã thiết lập.
2. **Gia hạn công việc** — đẩy ngày hoàn thành sang mốc mới, với giới hạn số ngày tối đa cho mỗi lần do quản trị viên đặt. Gia hạn cũng có **lưu trình ký riêng**: khi dự án khai báo lưu trình gia hạn, đơn phải ký đủ các bước thì ngày hoàn thành mới đổi.

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

## Lưu trình ký cho gia hạn

Có hai **loại** lưu trình, khai báo cùng một chỗ trong Cài đặt dự án:

| Loại | Ký để làm gì |
|---|---|
| **Duyệt công việc** | ký chuyển công việc qua các trạng thái |
| **Duyệt gia hạn** | duyệt đơn xin gia hạn; **không** đụng tới trạng thái công việc |

Khi tracker **có** lưu trình gia hạn:

1. Người xin gia hạn bấm *Gia hạn* như cũ. Đơn được tạo ở trạng thái **Chờ
   duyệt** — **ngày hoàn thành của công việc không đổi**.
2. Đơn hiện trên trang công việc kèm đầy đủ lưu trình, và trên chuông + trang
   *Công việc chờ tôi ký* của đúng người đang tới lượt.
3. Mỗi bước duyệt đẩy đơn sang bước sau. **Chỉ khi bước cuối duyệt** thì
   `due_date` mới nhảy sang mốc mới, kèm một journal ghi lại thay đổi đó.
4. Bị **từ chối** ở bất kỳ bước nào: đơn đóng lại ở trạng thái *Đã từ chối*,
   ngày hoàn thành giữ nguyên.

Không khai báo lưu trình gia hạn thì mọi thứ chạy y như trước: bấm là đổi ngày
ngay.

### Bước gia hạn bắt buộc chỉ định người ký

Bước của lưu trình công việc lấy quyền ký từ *chuyển trạng thái*. Bước gia hạn
**không có trạng thái đích** nên không có chuyển trạng thái nào để dựa vào — vì
vậy mỗi bước gia hạn **bắt buộc** phải chỉ định người ký: một vai trò, một
người, hoặc *Người thực hiện*. Mô hình từ chối lưu bước thiếu người ký.

Ngoài chỉ định đó, người ký vẫn phải sửa được công việc và **không** bị khoá
trường `due_date` ở trạng thái hiện tại — đúng quy tắc quyền gia hạn nêu trên.

### Đơn bị từ chối không tính vào hạn mức

Giới hạn *Số lần gia hạn tối đa* chỉ đếm đơn **đã duyệt** và đơn **đang chờ**.
Một lần bị từ chối không làm mất suất của người xin.

### Chữ ký gia hạn tách hẳn khỏi lưu trình công việc

Cả hai dùng chung bảng `approval_signatures`, phân biệt bằng cột
`issue_extension_id`. Quan hệ `Issue#approval_signatures` được giới hạn ở
`issue_extension_id IS NULL`, nên duyệt một cái hạn **không bao giờ** đẩy lưu
trình công việc tiến thêm một bước.

## Nút chuông cạnh ảnh đại diện

Góc phải thanh trên cùng, ngay cạnh nút profile, có **nút chuông** với số đếm
đỏ. Nhấp vào mở panel gồm ba phần:

- **Chờ tôi ký** — mỗi dòng hiện mã công việc, tiêu đề, dự án, tên bước và
  trạng thái sẽ chuyển sang; kèm **nút ký nhanh** (dùng đúng nhãn của bước, có
  hộp xác nhận) và liên kết *Ký kèm ý kiến* nếu muốn ghi chú.
- **Đơn gia hạn chờ tôi duyệt** — mỗi dòng hiện công việc, tên bước và mốc ngày
  đang xin (`cũ → mới`), kèm nút duyệt nhanh có hộp xác nhận.
- **Công việc quá hạn** — việc đang mở được giao cho bạn (hoặc cho nhóm của
  bạn) đã qua hạn, kèm số ngày trễ.

Chuông dùng lại Stimulus controller `dropdown` của Redmine nên tự đóng khi bấm
ra ngoài hoặc nhấn Escape. Chuông ẩn với khách chưa đăng nhập, và quản trị viên
có thể tắt hẳn trong cấu hình plugin.

Redmine không có hook nào ở khu vực profile-menu lẫn chân trang. Thay vì vá
`base.html.erb`, chuông và dòng chân trang được render trên hook **có sẵn**
`view_layouts_base_body_bottom` vào một `<div hidden>`, rồi một đoạn script nội
tuyến dời chúng vào `.profile-menu` và `#footer`. Script chạy cuối `<body>` nên
cả hai đích đã có trong DOM; thứ nào không tìm được đích thì bị bỏ cùng div ẩn
chứ không rơi lạc xuống cuối trang. Redmine không bật CSP nên script nội tuyến
chạy bình thường.

**Về hiệu năng** — mục này render trên *mọi* trang, nên phép tra cứu được viết
theo lô: routes, chữ ký và workflow transitions mỗi thứ lấy **một** lần rồi
đối chiếu trong bộ nhớ. Số query **không tăng theo số lượng issue**
(đo được: 26 query với 3 issue, vẫn 26 query với 43 issue). Nếu gọi thẳng
`Issue#can_approve?` cho từng issue thì tốn ~10 query/issue.

`Issue#can_approve?` vẫn là chuẩn mực — controller dùng nó — và
`PendingApprovalsTest` ghim đường nhanh vào nó bằng các test so sánh kết quả
hai bên. **Sửa một bên thì phải sửa bên kia.**

Danh sách quá hạn tốn thêm đúng **một** truy vấn, giới hạn 20 dòng.

Phần đơn gia hạn đi theo đường khác: bước gia hạn không dựa vào chuyển trạng
thái nên không có bộ lọc SQL nào rẻ để bám vào. Bù lại, tập đơn **đang chờ**
vốn đã rất nhỏ (chỉ những đơn chưa ai quyết), nên nó được nạp thẳng rồi lọc
trong bộ nhớ.

Quản trị viên có thể tắt chuông (Quản trị → Plugins → Cấu hình) nếu máy chủ yếu.

## Thanh nổi khi cuộn trang công việc

Redmine 7 có sẵn một thanh ngang cố định trên đầu trang công việc
(`#sticky-issue-header`), hiện ra khi tiêu đề đã cuộn khuất — nhưng nửa bên
phải của nó bỏ trống. Plugin dùng đúng chỗ trống đó: **bước đang chờ ký** kèm
trạng thái đích, và các **nút thao tác** (ký theo nhãn của bước, từ chối, gia
hạn, hoặc duyệt đơn gia hạn đang chờ chính bạn).

Nhờ vậy, với công việc dài, không phải cuộn ngược lên panel mới bấm được nút.

Cách làm giống hệt nút chuông: Redmine không có hook nào bên trong thanh đó,
nên khối này được render **ẩn** ngay tại hook có sẵn của panel, rồi một đoạn
script nội tuyến gắn nó vào `#sticky-issue-header`. Thanh nổi được parse trước
hook nên lúc script chạy phần tử đã có; một bản Redmine sau này đổi tên hay bỏ
phần tử đó thì khối đơn giản không hiện, chứ không rơi lạc ra giữa trang. Trên
màn hình hẹp (< 900px) khối bị ẩn, nhường chỗ cho tiêu đề.

`ApprovalPanelTest` kiểm chứng cả hai phía: `#sticky-issue-header` vẫn do core
dựng, và khối của plugin có đúng bước cùng các nút.

## Gửi email khi tới lượt ký (tuỳ chọn)

Bật tại **Quản trị → Plugins → Cấu hình → Gửi email khi tới lượt ký**.
**Mặc định tắt** — hãy kiểm tra cấu hình email của bạn trước khi bật.

Mail được gửi khi:

- tạo công việc mới thuộc tracker có lưu trình (bước 1 lập tức chờ ký);
- ai đó **ký duyệt** xong, bước kế tiếp chuyển sang người khác — hoặc, với bước
  AND, tới lượt người kế tiếp **trong cùng bước**;
- ai đó **từ chối**, công việc trả về bước trước đó;
- có **đơn xin gia hạn** mới, hoặc một bước gia hạn vừa được ký và tới lượt
  người sau. Đơn đã duyệt xong hoặc đã bị từ chối thì không gửi cho ai nữa.

Người nhận là những ai có quyền ký bước đang chờ — tức là có quyền chuyển sang
trạng thái đích của bước đó. Bước OR gửi cho **cả danh sách**; bước AND chỉ gửi
cho **người kế tiếp chưa ký**. Danh sách được thu hẹp trước bằng các vai trò thật
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

## Không sửa một file core nào

Toàn bộ plugin nằm gọn trong `plugins/redmine_approval_workflow/`. Kiểm chứng:

```bash
git diff origin/master -- . ':(exclude)plugins/'
# chỉ còn .gitignore (để git theo dõi được thư mục plugin)
```

Điều này quan trọng khi nâng cấp Redmine: một bản sao `config/routes.rb` hay
`lib/redmine/preparation.rb` bị ghim lại sẽ **âm thầm xoá** mọi route và quyền
mà bản mới thêm vào — app vẫn chạy, vẫn xanh healthcheck, chỉ là sai. Không có
file core nào bị ghi đè thì rủi ro đó biến mất, và triển khai chỉ còn là copy
một thư mục.

Năm thứ từng phải sửa core, nay nằm trong plugin:

| Việc | Chỗ ở mới |
|---|---|
| Route `/sw.js` | `config/routes.rb` của plugin — Redmine eval nó *bên trong* `routes.draw`, sau mọi route core |
| Action + view `/sw.js` | `ServiceWorkerController` + `app/views/service_worker/show.js.erb` của plugin |
| Menu Help → "Liên hệ" | `Redmine::MenuManager::Mapper#delete(:help)` rồi push lại, trong `init.rb` |
| Chuông + dòng chân trang | hook `view_layouts_base_body_bottom` + script dời chỗ |
| Khối thao tác trên thanh nổi | hook của panel + script gắn vào `#sticky-issue-header` |

## Kill-switch `/sw.js`

Plugin phục vụ một service worker tự huỷ tại `/sw.js`. Redmine không có service
worker, nhưng trình duyệt từng đăng ký một cái ở cùng origin sẽ hỏi `/sw.js`
mỗi lần điều hướng. Trả 404 **không** gỡ được nó — nó vẫn kiểm soát site và có
thể phục vụ asset cũ từ cache riêng. Trả về một worker tự xoá cache rồi
`unregister()` giúp các máy đó tự dọn.

Hai chi tiết khiến nó không thể là một controller bình thường:

- `skip_before_action :check_if_login_required, :check_password_change,
  :check_twofa_activation` — worker được nạp trước khi ai đăng nhập, và trình
  duyệt đọc một redirect sang trang login là script hỏng.
- `skip_after_action :verify_same_origin_request` — `protect_from_forgery` chặn
  mọi response `text/javascript` cho GET không có `X-Requested-With`, mà service
  worker được nạp đúng kiểu đó. Thiếu dòng này là **422**, không phải 200.

## Cài đặt

```bash
# copy thư mục plugin vào plugins/ rồi:
bundle exec rake redmine:plugins:migrate RAILS_ENV=production
# restart Redmine
```

Bật module **Lưu trình ký & Gia hạn** trong Cài đặt dự án → Mô-đun.

## Thiết lập — trong từng dự án

Lưu trình được khai báo tại **Cài đặt dự án → thẻ "Lưu trình ký"**, và **chỉ áp
dụng cho dự án đó**. Cần quyền *Quản lý lưu trình ký* (Quản trị → Vai trò).

Mỗi lưu trình gồm tên, **loại** (*Duyệt công việc* hay *Duyệt gia hạn*),
**danh sách kiểu vấn đề**, trạng thái khi bị từ chối, và danh sách bước. Loại
**không đổi được** sau khi đã lưu — đổi loại là đổi hẳn ý nghĩa của các chữ ký
đã ghi.

Một lưu trình **áp dụng cho nhiều kiểu vấn đề** cùng lúc: chọn bao nhiêu tracker
cũng được, mỗi cái là một thẻ. Không chọn cái nào thì lưu trình không quản việc
gì cả, nên mô hình từ chối lưu.

Mỗi **bước** khai báo:

| Trường | Ý nghĩa |
|---|---|
| Tên bước | ví dụ "Trưởng bộ phận duyệt" |
| Trạng thái sau khi ký | trạng thái công việc chuyển sang — **chỉ có ở lưu trình công việc** |
| **Người ký** | **danh sách** có thứ tự: **Người thực hiện**, các **vai trò**, các **người** cụ thể; **bắt buộc** với bước gia hạn |
| **Cách ký** | *Một người bất kỳ (OR)* hoặc *Tất cả, theo thứ tự (AND)* |
| **Nhãn nút** | chữ trên nút thao tác, ví dụ "Trình ký", "Phê duyệt"; để trống = "Ký duyệt" |
| **Giao việc cho người ký** | ký xong bước này thì người ký thành *Người thực hiện* — dùng cho bước "Nhận việc" |

Bảng bước có nút **"Thêm bước"** để thêm dòng, nên lưu trình dài bao nhiêu bước
cũng khai báo được. Dòng mới tự nhận số thứ tự kế tiếp; khi lưu, thứ tự được
đánh lại 0..n-1 theo đúng thứ tự trên form.

### OR và AND

| Cách ký | Nghĩa |
|---|---|
| **Một người bất kỳ (OR)** | ai trong danh sách ký trước là xong bước; thứ tự chỉ là thứ tự hiển thị |
| **Tất cả, theo thứ tự (AND)** | mọi người đều phải ký, và **đúng theo thứ tự các thẻ** — chỉ người kế tiếp chưa ký mới bấm được nút |

Với AND, mỗi chữ ký giữa chừng **không** làm công việc đổi trạng thái: nó chỉ
được ghi lại, panel vẫn dừng ở bước đó, và thông báo nói rõ còn chờ ai. Trạng
thái chỉ chuyển sau chữ ký cuối cùng. Ý kiến gõ kèm một chữ ký giữa chừng vẫn
vào lịch sử công việc như bình thường.

Bị **từ chối** ở bất kỳ đâu trong bước AND thì lưu trình lùi một bước và những
chữ ký bước đó đã gom **không còn tính** — phải ký lại từ đầu bước.

Một bước được **suy ra từ lịch sử** (mục "Tự khớp với trạng thái thật" bên dưới)
tính là đã qua trọn vẹn, kể cả ở chế độ AND: lịch sử ghi việc công việc đã
chuyển trạng thái, chứ không ghi ai đã điền ô nào.

### "Nhận việc" — giao việc cho chính người bấm nút

Tick **Giao việc cho người ký** ở một bước thì chữ ký **làm xong bước đó** đồng
thời đặt người vừa ký thành *Người thực hiện* của công việc. Đúng kiểu bước
"Nhận việc": ai nhận thì việc về tay người đó, không cần ai gán thủ công.

- Với bước **OR**, ai bấm trước thì người đó nhận.
- Với bước **AND**, việc về tay người **ký cuối cùng** — người làm xong bước.
  Các chữ ký giữa chừng không đổi người thực hiện.
- **Từ chối** không giao việc cho ai cả.
- Việc giao nằm **chung một mục lịch sử** với lần đổi trạng thái, không phải một
  lần sửa thứ hai.
- Nút ký nhanh trên chuông đi qua đúng action đó nên cũng giao việc.

Tùy chọn này **không** cấp thêm quyền cho ai. Nó vẫn tuân hai điều kiện của
Redmine, và khi bị chặn thì **nói ra** chứ không im lặng:

| Bị chặn khi | Kết quả |
|---|---|
| Luồng công việc đặt *Người thực hiện* là **Chỉ đọc** cho vai trò đó, ở trạng thái hiện tại | vẫn ký được, kèm cảnh báo "chưa giao việc được" |
| Người ký không nằm trong danh sách được giao việc của công việc | vẫn ký được, kèm cảnh báo |

Quyền trên trường được đọc ở **trạng thái công việc đang đứng**, tức trạng thái
người đó thao tác *từ* đó — cùng cái trạng thái dùng để xét mọi quyền khác của
lần ký này.

Bước của lưu trình **gia hạn** không có ô này: đơn gia hạn quyết một cái ngày,
nó không có việc gì phải chuyển người làm.

### Thẻ: chọn xong giữ lại, kéo thả đổi thứ tự, bấm × để bỏ

Cả danh sách kiểu vấn đề lẫn danh sách người ký đều dùng chung một kiểu điều
khiển: chọn từ ô thả xuống rồi bấm *Thêm*, thứ vừa chọn **ở lại thành một thẻ**
trong hàng. Kéo thả thẻ để đổi thứ tự, bấm **×** để bỏ. Chính các thẻ là trường
dữ liệu — mỗi thẻ mang một input ẩn, và thứ tự các thẻ chính là thứ tự được gửi
đi. Danh sách kiểu vấn đề không kéo thả được vì thứ tự tracker không mang ý
nghĩa gì.

### Chỉ định người ký vẫn chỉ thu hẹp

Điểm quan trọng không đổi: danh sách người ký **lọc bên trong** quyền chuyển
trạng thái, không thay thế nó. Có tên trong danh sách mà luồng công việc không
cho chuyển trạng thái thì vẫn không ký được.

> Một lỗ hổng đi kèm đã được vá trong lần này: trước đây `ApprovalsController`
> chỉ kiểm tra quyền chuyển trạng thái mà **không** kiểm tra danh sách người ký,
> nên người có quyền chuyển trạng thái có thể POST thẳng vào endpoint để ký bước
> của người khác — nút thì bị ẩn, endpoint thì không. Nay endpoint kiểm tra cả
> hai, và có test riêng cho nó.

### "Người thực hiện" — người ký lấy theo công việc

Chọn **Người thực hiện** thì bước đó thuộc về người đang được giao công việc
*tại thời điểm ký*, không phải một cái tên cố định trong cấu hình. Một lưu trình
duy nhất vì thế dùng được cho mọi công việc của tracker: bước "Nhận việc" luôn
rơi đúng vào người được giao.

- Công việc giao cho một **nhóm** thì mọi thành viên của nhóm đều ký được, đúng
  như cách Redmine hiểu trường *Được giao cho* ở mọi nơi khác.
- Công việc **chưa giao cho ai** thì không ai ký được bước đó — không có người
  thực hiện để đối chiếu.
- Đổi người được giao là đổi luôn người ký, ngay lập tức.

### Công thức đầy đủ

Nền tảng vẫn là quyền chuyển trạng thái trong luồng công việc. Chỉ định ở bước
lọc thêm bên trong đó:

```
được ký  =  luồng công việc cho phép chuyển trạng thái
            VÀ (danh sách người ký rỗng
                HOẶC OR: có tên trong danh sách
                HOẶC AND: là người kế tiếp chưa ký trong danh sách)
```

Chỉ định một người **không** cấp cho họ quyền chuyển trạng thái mà luồng công
việc từ chối — kể cả *Người thực hiện*: người được giao việc mà luồng công việc
không cho chuyển trạng thái thì vẫn không ký được. Có test riêng cho cả hai
chiều.

Khi bước đã chỉ định, **chỉ người đó** thấy nút ký, thấy công việc trên chuông,
và nhận email. Ba nơi dùng chung một quy tắc.

**Quản trị → Plugins → Cấu hình**:

| Thiết lập | Mặc định | Ý nghĩa |
|---|---|---|
| Số ngày tối đa mỗi lần gia hạn | 30 | 0 = không giới hạn |
| Số lần gia hạn tối đa | 0 | 0 = không giới hạn |
| Bắt buộc nhập lý do gia hạn | có | |
| Hiện nút nhắc ký trên thanh menu | có | tắt để giảm tải máy chủ |
| Gửi email khi tới lượt ký | **không** | xem mục riêng bên dưới |
| Tự động khớp lưu trình theo trạng thái | có | xem mục riêng bên dưới |

## Tự khớp với trạng thái thật, điền từ lịch sử

Công việc đi vào một trạng thái bằng nhiều đường: tạo trước khi lưu trình tồn
tại, sửa bằng form thường, API, sửa hàng loạt, nhập dữ liệu. Nếu bỏ mặc, lưu
trình sẽ hiện "chưa ký bước nào" trong khi công việc đã nằm ở trạng thái của
bước 3.

Plugin đọc **lịch sử thật** của công việc — trạng thái lúc tạo, rồi từng journal
đổi `status_id` — đối chiếu theo thứ tự với các bước, và điền vào bước nào đã đi
qua, kèm **ai đã chuyển và lúc nào**, lấy đúng từ journal đó.

### Những bản ghi này KHÔNG phải chữ ký

Chúng mang cờ `derived` và hiện rõ nhãn **"suy ra từ lịch sử"** trong panel lẫn
trang lịch sử ký, kèm liên kết tới đúng thay đổi trong lịch sử công việc. Lưu
trình ký là hồ sơ kiểm toán — một lần đổi trạng thái qua form thường **không**
phải một lần ký, và giao diện không được để lẫn hai thứ đó.

### Ba đường kích hoạt

| Đường | Khi nào |
|---|---|
| **Tự động** | mỗi lần `status_id` đổi ngoài lưu trình (`after_save`) |
| **Nút "Đồng bộ từ lịch sử"** | trên panel, cần quyền *Đồng bộ lưu trình từ lịch sử* |
| **Rake task** | dữ liệu cũ hàng loạt, khi mới cài plugin |

```bash
# Xem trước, không ghi gì
bundle exec rake redmine:approval_workflow:backfill DRY_RUN=1 RAILS_ENV=production

# Chạy thật, có thể giới hạn một dự án
bundle exec rake redmine:approval_workflow:backfill PROJECT=an-toan-chay RAILS_ENV=production
```

Quy tắc an toàn:

- **Không bao giờ ghi đè chữ ký thật.** Bước đã có bản ghi thì bỏ qua.
- **Chỉ điền tiến về phía trước**, từ vị trí hiện tại của lưu trình.
- **Chạy lại bao nhiêu lần cũng được** — lần hai không thêm gì. Journal nào đã
  được một chữ ký trỏ tới thì bị loại theo `journal_id` chứ không theo thời
  gian, vì controller ghi journal và chữ ký trong cùng một transaction nên hai
  mốc thời gian có thể bằng nhau.
- **Đường vòng không tính.** Công việc đi 1 → 4 → 2 với lưu trình `[2, 3]` chỉ
  khớp bước 1; trạng thái 4 nằm ngoài lưu trình nên bị bỏ qua.
- Đổi trạng thái **bằng chính nút ký** không bị đếm hai lần — controller đánh
  dấu lần lưu đó.

Tắt phần tự động tại **Quản trị → Plugins → Cấu hình** nếu muốn chỉ chạy thủ công.

## Cách hoạt động

Tiến độ lưu trình được suy ra từ bảng `approval_signatures`, **không** từ
trạng thái công việc. Nhờ vậy một lần đổi trạng thái thủ công bên ngoài lưu
trình không thể lặng lẽ bỏ qua một bước — khi lệch, panel hiện cảnh báo.

- **Ký duyệt** bước `p`: trạng thái → status của bước `p`, con trỏ tiến lên `p+1`.
- **Từ chối** bước `p`: con trỏ lùi về `max(0, p-1)`; trạng thái về status của
  bước `p-2`, hoặc "trạng thái khi bị từ chối" nếu đang ở đầu lưu trình.

Mỗi thao tác đều tạo một journal trên công việc, nên lịch sử hiển thị đầy đủ
trong tab thông thường của Redmine.

### Ký duyệt không tự thêm bình luận

Journal chỉ ghi **thay đổi trạng thái** (hoặc thay đổi `due_date` với gia hạn).
Phần ghi chú của journal để trống trừ khi người ký tự gõ vào ô *Ý kiến* — plugin
không sinh ra dòng "Ký duyệt bước: ..." nào nữa. Ý kiến đã gõ vẫn được lưu hai
chỗ: trong journal và trong chính bản ghi chữ ký (hiện trên panel lưu trình).

## Quyền

| Quyền | Tác dụng |
|---|---|
| Xem lưu trình ký | Hiện panel lưu trình trên trang công việc |
| Gia hạn công việc | Cho phép bấm nút Gia hạn (còn phải qua quyền trên trường `due_date`) |
| Quản lý lưu trình ký | Hiện thẻ "Lưu trình ký" trong Cài đặt dự án |
| Đồng bộ lưu trình từ lịch sử | Hiện nút "Đồng bộ từ lịch sử" trên panel |

## Kiểm thử

```bash
bundle exec rails test plugins/redmine_approval_workflow/test RAILS_ENV=test
```

271 test, 1046 assertion.
